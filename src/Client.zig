//! Connection to the local Discord client.
//!
//! `start` runs a reader task and a writer task; the caller collects what they record with
//! `nextEvent`. Every entry point is safe to call from any task.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const Backoff = @import("Backoff.zig");
const Presence = @import("Presence.zig");
const User = @import("User.zig");
const text = @import("text.zig");
const rpc = @import("rpc/root.zig");
const Transport = @import("transport/root.zig").Transport;
const milliseconds = @import("timeout.zig").milliseconds;

const Connection = rpc.Connection;
const serialize = rpc.serialize;
const parse = rpc.parse;

const Client = @This();

pub const max_presence_size: u32 = 12 * 1024;
pub const max_command_size: u32 = 512;

/// A command too wide for a slab slot gets a buffer of its own. Only the voice configuration
/// and the certified device list reach this size, and a caller sends those at setup, so one
/// buffer holds them all.
pub const max_bulk_command_size: u32 = 3 * 1024;

pub const outbound_capacity: u32 = 8;
pub const join_request_capacity: u32 = 8;
/// Each entry carries what its event arrived with, so this is the widest queue a client holds.
pub const notice_capacity: u32 = 16;

/// How many events, each keyed to its own guild or channel, one client may ask for at once.
pub const subscription_capacity: u32 = 32;

/// How many requests may wait for a reply at once. A caller past this is told to retry.
pub const request_capacity: u32 = 4;

const slot_size: u32 = Connection.header_size + max_command_size;

/// Two past the queue's capacity: the writer holds one entry outside the queue, and
/// `enqueue` fills its slot before it learns whether the queue has room.
const slab_slots: u32 = outbound_capacity + 2;

comptime {
    assert(slab_slots > outbound_capacity + 1);
}

/// Bounds the pre-ready state, which is the one state no event reports.
const handshake_timeout_ms: u64 = 10 * 1000;

/// A whole frame, so a payload is read entire and walked in memory, and a ping's answer is
/// staged behind its own header in the same room.
const chunk_bytes: u32 = Connection.max_frame_size;

const reconnect_min_ms: i64 = 500;
const reconnect_max_ms: i64 = 60 * 1000;

/// A tripwire on the size of a client, checked below. Most of it is the payload buffer, which
/// holds the widest frame the protocol carries so a frame is walked in memory.
pub const max_footprint_bytes: u32 = 128 * 1024;

comptime {
    assert(@sizeOf(Client) <= max_footprint_bytes);
}

pub const Reply = serialize.Reply;

pub const Error = error{PayloadTooLarge} || Io.Cancelable;
pub const PresenceError = Error || error{InvalidPresence};

/// `InvalidApplicationId` covers an id that is empty or longer than the handshake carries.
pub const StartError = error{ AlreadyStarted, InvalidApplicationId } ||
    Io.ConcurrentError || Io.Cancelable;

pub const Event = union(enum) {
    ready: User,
    disconnected: Status,
    errored: Status,
    join_game: Secret,
    spectate_game: Secret,
    join_request: User,
    notice: Notice,
};

/// A subscribed event, and what it arrived carrying. `rpc.Event.shape` says which member of
/// `payload` the event fills.
pub const Notice = struct {
    event: rpc.Event,
    payload: rpc.Payload,

    const empty: Notice = .{ .event = .current_user_update, .payload = .none };
};

pub const Status = struct {
    code: i32 = 0,
    message: text.Buffer(parse.text_bytes) = .empty,

    pub const none: Status = .{};

    fn fromCode(code: Connection.ErrorCode) Status {
        assert(code != .success);
        var status: Status = .{ .code = @backingInt(code) };
        status.message.set(code.message());
        return status;
    }
};

pub const Secret = text.Buffer(parse.text_bytes);

/// One event this client asks for, and the guild or channel it is scoped to. A subscription
/// lives only as long as the connection that carries it, so `sent` is what the connection in
/// hand has been told and `wanted` is what the caller asked for.
const Subscription = struct {
    /// Null on an entry holding no subscription, which is the one state the
    /// flags read false in together.
    event: ?rpc.Event,
    key: Key,
    wanted: bool,
    sent: bool,

    const Key = text.Buffer(rpc.snowflake_bytes);

    const empty: Subscription = .{
        .event = null,
        .key = .empty,
        .wanted = false,
        .sent = false,
    };
};

pub const Options = struct {
    application_id: []const u8,
};

/// The payload lives in the slab. `epoch` is the connection it was built for.
const Outbound = struct {
    kind: Kind,
    slot: u8,
    length: u16,
    epoch: u32,

    const Kind = enum(u8) { command, bulk, presence };

    comptime {
        assert(slab_slots <= std.math.maxInt(u8));
        assert(max_command_size <= std.math.maxInt(u16));
        assert(max_bulk_command_size <= std.math.maxInt(u16));
    }
};

/// A bit is never cleared by anyone but the taker.
const Signals = packed struct(u8) {
    connected: bool = false,
    disconnected: bool = false,
    errored: bool = false,
    join_game: bool = false,
    spectate_game: bool = false,
    unused: u3 = 0,
};

connection: Connection,
process_id: u32,

/// The id `init` was given, so `start` can tell a stored id from a shortened one.
application_id_length: u32,
nonce: std.atomic.Value(u32),

/// Reads stay outside this, so a blocked read cannot stall a send.
write_mutex: Io.Mutex,
connected_condition: Io.Condition,

/// Which connection, and whether it is up: odd while one is live, even between. Read without
/// the lock; a queued command carries the epoch it was built for and is dropped if it differs.
epoch: std.atomic.Value(u32),

/// What the caller asks for and what the current connection has been told; both `subscribe`
/// and a reconnect diff the two.
subscription_mutex: Io.Mutex,
subscriptions: [subscription_capacity]Subscription,

record_mutex: Io.Mutex,
connected_user: User,
last_error: Status,
last_disconnect: Status,
join_game_secret: Secret,
spectate_game_secret: Secret,

signals: std.atomic.Value(u8),

/// Where a caller waits for the reader to record something: an event, or the reply to a
/// request. Held across both the record and the check, so a caller that has looked and has
/// yet to wait still sees what arrived between the two.
waiter_mutex: Io.Mutex,
waiter_condition: Io.Condition,

/// Requests waiting for the reply Discord echoes their nonce back on.
pending: [request_capacity]Pending,

/// Every slot reserves a frame header ahead of its command.
send_mutex: Io.Mutex,
outbound_slab: [slab_slots * slot_size]u8,
next_slot: u32,
outbound_queue: Io.Queue(Outbound),
outbound_storage: [outbound_capacity]Outbound,

/// One buffer for the wide commands, behind its own header.
bulk_mutex: Io.Mutex,
bulk_payload: [Connection.header_size + max_bulk_command_size]u8,
bulk_length: u32,
/// Set while a queued command still refers to the buffer, so the next caller waits its turn.
bulk_sending: bool,

/// Two slots, so a caller fills one while the writer transmits from the other.
presence_mutex: Io.Mutex,
presence_payload: [2][Connection.header_size + max_presence_size]u8,
presence_length: [2]u32,
/// The slot holding the newest complete presence; it outlives the send that carried it, so a
/// reconnect can offer it again.
presence_latest: ?u1,
/// The slot on the wire. A caller fills the other one.
presence_sending: ?u1,
presence_pending: bool,

join_request_queue: Io.Queue(User),
join_request_storage: [join_request_capacity]User,

/// Subscribed events reported by name alone.
notice_queue: Io.Queue(Notice),
notice_storage: [notice_capacity]Notice,

chunk_buffer: [chunk_bytes]u8,

backoff: Backoff,
pump: Io.Group,
started: bool,

/// A client must not be moved or copied after this: its queues point into its own storage.
/// At `max_footprint_bytes` it belongs in static storage or on the heap.
pub fn init(client: *Client, options: Options) void {
    client.* = .{
        .connection = .init(options.application_id),
        .application_id_length = std.math.cast(u32, options.application_id.len) orelse
            std.math.maxInt(u32),
        .process_id = Transport.processId(),
        .nonce = .init(1),
        .write_mutex = .init,
        .connected_condition = .init,
        .epoch = .init(0),
        .subscription_mutex = .init,
        .subscriptions = @splat(.empty),
        .record_mutex = .init,
        .connected_user = .empty,
        .last_error = .none,
        .last_disconnect = .none,
        .join_game_secret = .empty,
        .spectate_game_secret = .empty,
        .signals = .init(0),
        .waiter_mutex = .init,
        .waiter_condition = .init,
        .pending = @splat(.empty),
        .send_mutex = .init,
        .outbound_slab = undefined,
        .next_slot = 0,
        .outbound_queue = undefined,
        .outbound_storage = undefined,
        .bulk_mutex = .init,
        .bulk_payload = undefined,
        .bulk_length = 0,
        .bulk_sending = false,
        .presence_mutex = .init,
        .presence_payload = undefined,
        .presence_length = @splat(0),
        .presence_latest = null,
        .presence_sending = null,
        .presence_pending = false,
        .join_request_queue = undefined,
        .join_request_storage = undefined,
        .notice_queue = undefined,
        .notice_storage = undefined,
        .chunk_buffer = undefined,
        .backoff = .init(reconnect_min_ms, reconnect_max_ms, 0),
        .pump = .init,
        .started = false,
    };

    client.outbound_queue = .init(&client.outbound_storage);
    client.join_request_queue = .init(&client.join_request_storage);
    client.notice_queue = .init(&client.notice_storage);

    assert(client.outbound_queue.capacity() == outbound_capacity);
    assert(client.join_request_queue.capacity() == join_request_capacity);
    assert(client.notice_queue.capacity() == notice_capacity);
}

pub fn deinit(client: *Client, io: Io) void {
    if (client.isRunning()) client.stop(io);
    assert(!client.isRunning());

    assert(!client.isConnected());
    client.connection.deinit(io);
    client.* = undefined;
}

/// Starts the reader and writer tasks. The application id is validated here, since `init`
/// cannot fail; an id too long for the handshake would connect as a different application.
pub fn start(
    client: *Client,
    io: Io,
    environ: *std.process.Environ.Map,
) StartError!void {
    if (client.started) return error.AlreadyStarted;
    if (client.application_id_length == 0) return error.InvalidApplicationId;
    if (client.connection.application_id.len != client.application_id_length) {
        return error.InvalidApplicationId;
    }

    const seed: u64 = @bitCast(Io.Clock.real.now(io).toMicroseconds());
    client.backoff = .init(reconnect_min_ms, reconnect_max_ms, seed);

    // A closed queue stays closed, so a restart needs fresh ones.
    client.outbound_queue = .init(&client.outbound_storage);
    client.join_request_queue = .init(&client.join_request_storage);
    client.notice_queue = .init(&client.notice_storage);
    client.next_slot = 0;
    client.presence_pending = false;

    // The queue a stopped client dropped took the command holding the buffer with it.
    client.bulk_sending = false;
    client.bulk_length = 0;
    client.signals.store(0, .release);

    try client.pump.concurrent(io, pumpReads, .{ client, io, environ });
    errdefer {
        // The reader may already have opened a connection; a later `start` would resume
        // reading mid-frame from it.
        client.pump.cancel(io);
        client.closeConnection(io);
    }
    try client.pump.concurrent(io, pumpWrites, .{ client, io });

    client.started = true;
    assert(client.started);
}

pub fn isRunning(client: *const Client) bool {
    return client.started;
}

/// Stopping a client that never ran is nothing to do, so this is safe to `defer`.
pub fn stop(client: *Client, io: Io) void {
    if (!client.started) return;
    client.outbound_queue.close(io);
    client.join_request_queue.close(io);
    client.pump.cancel(io);

    // Cancellation can land mid-frame, so the transport is dropped and a restart is fresh.
    client.closeConnection(io);

    client.started = false;
    assert(!client.started);
    assert(!client.connection.isOpen());

    // Released after the flag clears, so a waiter that wakes here sees a stopped client.
    client.wakeWaiters(io);
}

pub fn updatePresence(client: *Client, io: Io, presence: ?*const Presence) PresenceError!void {
    {
        client.presence_mutex.lockUncancelable(io);
        defer client.presence_mutex.unlock(io);

        // Whichever slot is off the wire. Serialising costs no IO, so the lock is held over
        // it without a caller ever waiting on the peer.
        const slot: u1 = if (client.presence_sending) |sending| ~sending else 0;
        assert(client.presence_sending == null or slot != client.presence_sending.?);

        // A failed serialisation leaves a fragment here, so the slot stops being a presence
        // until a whole one is in it.
        client.presence_length[slot] = 0;
        if (client.presence_latest == slot) client.presence_latest = null;

        const length = serialize.richPresence(
            client.presence_payload[slot][Connection.header_size..],
            client.nextNonce(),
            client.process_id,
            presence,
        ) catch |err| switch (err) {
            error.WriteFailed => return error.PayloadTooLarge,
            error.InvalidPresence => |e| return e,
        };
        assert(length > 0);
        assert(length <= max_presence_size);

        client.presence_length[slot] = length;
        client.presence_latest = slot;
    }

    try client.armPresence(io);
}

/// A waiting presence is replaced, so at most one marker is ever outstanding.
fn armPresence(client: *Client, io: Io) Io.Cancelable!void {
    client.presence_mutex.lockUncancelable(io);
    defer client.presence_mutex.unlock(io);

    // A marker says only that some presence is waiting; the writer reads which one.
    assert(client.presence_latest != null);

    if (client.presence_pending) return;
    client.presence_pending = true;

    // A claim standing with no marker queued would stop every later arm from queueing one.
    var queued: usize = 0;
    defer if (queued == 0) {
        client.presence_pending = false;
    };

    // A presence carries no epoch: it belongs on whichever connection carries it.
    const marker: Outbound = .{
        .kind = .presence,
        .slot = 0,
        .length = 0,
        .epoch = 0,
    };
    queued = client.outbound_queue.put(io, &.{marker}, 0) catch |err| switch (err) {
        error.Closed => 0,
        error.Canceled => |e| return e,
    };
    assert(queued <= 1);
}

pub fn clearPresence(client: *Client, io: Io) Error!void {
    return client.updatePresence(io, null) catch |err| switch (err) {
        // Nothing is carried, so there is no field for the peer to reject.
        error.InvalidPresence => unreachable,
        else => |e| e,
    };
}

/// A snapshot, stale the instant it is read; `send` re-checks under the lock.
fn isConnected(client: *const Client) bool {
    return client.epoch.load(.acquire) % 2 == 1;
}

/// Only the reader publishes transitions, and `stop` only once it has been joined, so the
/// bump needs no compare-and-swap. A repeated transition leaves the epoch alone.
fn publishEpoch(client: *Client, live: bool) void {
    const current = client.epoch.load(.acquire);
    if (current % 2 == @intFromBool(live)) return;

    // Wrapping keeps the parity correct at the boundary; aliasing needs 2^32 transitions.
    client.epoch.store(current +% 1, .release);
    assert(client.isConnected() == live);
}

/// Nothing is queued while disconnected: a stale answer would refer to a forgotten request.
pub const RespondError = Error || error{ InvalidUser, Disconnected };

pub fn respond(client: *Client, io: Io, user_id: []const u8, reply: Reply) RespondError!void {
    if (user_id.len == 0) return error.InvalidUser;
    if (!client.isConnected()) return error.Disconnected;

    if (!try client.enqueue(io, client.nextNonce(), .{
        .join_reply = .{ .user_id = user_id, .reply = reply },
    })) return error.Disconnected;
}

/// `InvalidSubscription` is a key the event's scope will not take: one given to an event
/// Discord watches globally, one withheld from an event keyed by a guild or a channel, or one
/// wider than an id. `SubscriptionsFull` means `subscription_capacity` is spent.
pub const SubscribeError = Error || error{ InvalidSubscription, SubscriptionsFull };

/// Asks Discord to forward `subscribed`. `key` names the guild or channel the event is watched
/// on, and is empty for an event whose scope is global. A subscription made while disconnected
/// is carried by the next connection.
pub fn subscribe(
    client: *Client,
    io: Io,
    subscribed: rpc.Event,
    key: []const u8,
) SubscribeError!void {
    try checkScope(subscribed, key);
    try client.wantSubscription(io, subscribed, key, true);
    return client.syncSubscriptions(io);
}

/// Gives back a subscription. An event that was never asked for needs nothing sent.
pub fn unsubscribe(
    client: *Client,
    io: Io,
    subscribed: rpc.Event,
    key: []const u8,
) SubscribeError!void {
    try checkScope(subscribed, key);
    try client.wantSubscription(io, subscribed, key, false);
    return client.syncSubscriptions(io);
}

/// Whether the caller is asking for this event; the request may still be outstanding.
pub fn isSubscribed(client: *Client, io: Io, subscribed: rpc.Event, key: []const u8) bool {
    if (key.len > rpc.snowflake_bytes) return false;

    client.subscription_mutex.lockUncancelable(io);
    defer client.subscription_mutex.unlock(io);

    const entry = client.findSubscription(subscribed, key) orelse return false;
    assert(entry.event.? == subscribed);
    return entry.wanted;
}

/// A key travels in the argument its scope names, so the pairing is settled here, before
/// anything is recorded and long before Discord would answer for it.
fn checkScope(subscribed: rpc.Event, key: []const u8) error{InvalidSubscription}!void {
    if (key.len > rpc.snowflake_bytes) return error.InvalidSubscription;

    switch (subscribed.scope()) {
        .global => if (key.len > 0) return error.InvalidSubscription,
        .guild, .channel => if (key.len == 0) return error.InvalidSubscription,
    }
}

/// Assumes `subscription_mutex` is held.
fn findSubscription(client: *Client, subscribed: rpc.Event, key: []const u8) ?*Subscription {
    assert(key.len <= rpc.snowflake_bytes);

    for (&client.subscriptions) |*entry| {
        const held = entry.event orelse continue;
        if (held != subscribed) continue;
        if (std.mem.eql(u8, entry.key.slice(), key)) return entry;
    }
    return null;
}

/// Records what the caller wants without sending anything; `syncSubscriptions` carries it.
fn wantSubscription(
    client: *Client,
    io: Io,
    subscribed: rpc.Event,
    key: []const u8,
    wanted: bool,
) error{SubscriptionsFull}!void {
    assert(key.len <= rpc.snowflake_bytes);

    client.subscription_mutex.lockUncancelable(io);
    defer client.subscription_mutex.unlock(io);

    if (client.findSubscription(subscribed, key)) |entry| {
        entry.wanted = wanted;

        // Nothing is owed on an entry no connection was ever told about, so it frees here
        // and the slot goes back to the table.
        if (!entry.wanted and !entry.sent) entry.* = .empty;
        return;
    }
    if (!wanted) return;

    for (&client.subscriptions) |*entry| {
        if (entry.event != null) continue;
        assert(!entry.sent);

        entry.* = .{ .event = subscribed, .key = .empty, .wanted = true, .sent = false };
        entry.key.set(key);
        assert(entry.key.len == key.len);
        return;
    }
    return error.SubscriptionsFull;
}

/// A change made while disconnected needs nothing sent; the reconnect carries the whole set.
fn syncSubscriptions(client: *Client, io: Io) Error!void {
    client.subscription_mutex.lockUncancelable(io);
    defer client.subscription_mutex.unlock(io);

    if (!client.isConnected()) return;

    // Recorded one at a time: a change a full queue dropped stays outstanding
    // for the next sync to carry.
    for (&client.subscriptions) |*entry| {
        const subscribed = entry.event orelse continue;
        assert(entry.wanted or entry.sent);
        if (entry.wanted == entry.sent) continue;

        const action: serialize.Subscription = if (entry.wanted) .subscribe else .unsubscribe;
        const queued = try client.enqueue(io, client.nextNonce(), .{ .subscription = .{
            .action = action,
            .event = subscribed,
            .key = entry.key,
        } });
        if (!queued) return;

        // A given-back subscription is spent once the wire carries the word; the entry frees
        // for the next event to claim.
        if (entry.wanted) entry.sent = true else entry.* = .empty;
    }
}

/// A fresh connection has been told nothing, so the whole set is outstanding again.
fn resubscribe(client: *Client, io: Io) Error!void {
    client.subscription_mutex.lockUncancelable(io);
    for (&client.subscriptions) |*entry| {
        if (entry.event == null) continue;
        assert(entry.wanted or entry.sent);

        // An unsubscribe owed to a connection that is gone dies with it.
        if (entry.wanted) entry.sent = false else entry.* = .empty;
    }
    client.subscription_mutex.unlock(io);

    // Only the reader resubscribes, and only on a connection it has just seen greeted.
    assert(client.connection.state != .disconnected);

    return client.syncSubscriptions(io);
}

/// The next recorded event, or null. A disconnect is reported first while the connection is
/// back up and last while it is still down, so the sequence reads in order either way.
pub fn nextEvent(client: *Client, io: Io) Io.Cancelable!?Event {
    // Read once: reading again at the tail could report one disconnect twice.
    const is_connected = client.isConnected();

    if (is_connected) {
        if (client.takeDisconnect(io)) |status| return .{ .disconnected = status };
    }
    if (client.takeRecord(io, .{ .connected = true }, "connected_user")) |user| {
        return .{ .ready = user };
    }
    if (client.takeRecord(io, .{ .errored = true }, "last_error")) |status| {
        return .{ .errored = status };
    }
    if (client.takeRecord(io, .{ .join_game = true }, "join_game_secret")) |secret| {
        return .{ .join_game = secret };
    }
    if (client.takeRecord(io, .{ .spectate_game = true }, "spectate_game_secret")) |secret| {
        return .{ .spectate_game = secret };
    }
    if (try take(io, User, &client.join_request_queue)) |user| return .{ .join_request = user };
    if (try take(io, Notice, &client.notice_queue)) |raised| return .{ .notice = raised };

    if (!is_connected) {
        if (client.takeDisconnect(io)) |status| return .{ .disconnected = status };
    }

    return null;
}

fn takeDisconnect(client: *Client, io: Io) ?Status {
    return client.takeRecord(io, .{ .disconnected = true }, "last_disconnect");
}

/// The bit is claimed under the same lock that guards the record it announces, so the value
/// returned is the one that bit was raised for.
fn takeRecord(
    client: *Client,
    io: Io,
    signal: Signals,
    comptime field: []const u8,
) ?@FieldType(Client, field) {
    const mask: u8 = @bitCast(signal);
    assert(@popCount(mask) == 1);

    // The bit is raised after the record it announces, so a bit that is down means there is
    // nothing under the lock worth taking. A caller that reads it a moment too early is a
    // caller who polls again, which is what this call already asks of them.
    if (client.signals.load(.acquire) & mask == 0) return null;

    client.record_mutex.lockUncancelable(io);
    defer client.record_mutex.unlock(io);

    if (!client.takeSignal(signal)) return null;
    return @field(client, field);
}

fn take(io: Io, comptime Item: type, queue: *Io.Queue(Item)) Io.Cancelable!?Item {
    var items: [1]Item = undefined;
    const count = queue.get(io, &items, 0) catch |err| switch (err) {
        error.Closed => return null,
        error.Canceled => |e| return e,
    };
    assert(count <= 1);
    if (count == 0) return null;
    return items[0];
}

/// Blocks until `nextEvent` has something to hand back, and returns it. A `.none` timeout waits
/// for as long as the client runs; null means the timeout expired first.
///
/// `stop` wakes this, so a client shut down from another task does not strand a waiter.
pub fn waitEvent(client: *Client, io: Io, timeout: Io.Timeout) Io.Cancelable!?Event {
    const deadline = timeout.toDeadline(io);

    while (true) {
        if (try client.nextEvent(io)) |ready| return ready;
        if (!client.isRunning()) return null;

        client.waiter_mutex.lockUncancelable(io);
        defer client.waiter_mutex.unlock(io);

        client.waiter_condition.waitTimeout(io, &client.waiter_mutex, deadline) catch |err| {
            switch (err) {
                error.Timeout => return null,
                error.Canceled => |e| return e,
            }
        };
    }
}

/// `RequestsBusy` means every slot is held; the caller retries once one frees.
pub const RequestError = Error || parse.Error || error{ RequestsBusy, Disconnected };

/// A command Discord answered. `Refused` carries its own account of why, which `lastError`
/// names; every other member says the request was turned back before it was sent.
pub const AcceptError = RequestError || error{Refused};

pub const AuthorizeError = AcceptError || error{InvalidScopes};
pub const AuthenticateError = AcceptError || error{InvalidToken};

/// How long a command waits for the reply carrying its nonce.
pub const request_timeout_ms: u64 = 10 * 1000;

const request_timeout: Io.Timeout = milliseconds(request_timeout_ms);

/// Hands Discord a token the caller already exchanged for, and answers the account it belongs
/// to. The exchange that mints the token needs an application secret, so it happens
/// away from this library.
pub fn authenticate(client: *Client, io: Io, access_token: []const u8) AuthenticateError!User {
    if (access_token.len == 0) return error.InvalidToken;

    const reply = try client.accepted(io, .{
        .authenticate = .{ .access_token = access_token },
    }, null);
    return reply.user;
}

/// Puts Discord's consent modal in front of the user and answers the one-time code they
/// approved. Trading that code for a token carries an application secret, so it happens on a
/// server the application owns.
pub fn authorize(client: *Client, io: Io, scopes: []const []const u8) AuthorizeError!Secret {
    if (scopes.len == 0) return error.InvalidScopes;

    const reply = try client.accepted(io, .{ .authorize = .{ .scopes = scopes } }, null);
    if (reply.authorization.len == 0) return error.Refused;

    var code: Secret = .empty;
    code.set(reply.authorization.slice());
    return code;
}

/// A reply Discord agreed to. A refusal is put where `nextEvent` reports it, since the waiter
/// took the frame that carried it.
fn accepted(
    client: *Client,
    io: Io,
    command: Command,
    sink: ?parse.Sink,
) AcceptError!parse.Frame {
    const reply = try client.call(io, command, sink, request_timeout);
    assert(reply.has_nonce);

    if (std.mem.eql(u8, reply.event.slice(), rpc.errored)) {
        client.recordError(io, reply.code, reply.message);
        return error.Refused;
    }
    return reply;
}

pub const VoiceError = AcceptError || error{InvalidVoiceSettings};
pub const DeviceError = AcceptError || error{InvalidDevice};

/// The local voice configuration, as Discord holds it.
pub fn voiceSettings(client: *Client, io: Io) AcceptError!rpc.VoiceSettings {
    var settings: rpc.VoiceSettings = .empty;
    _ = try client.accepted(io, .voice_settings_query, .{ .voice_settings = &settings });
    return settings;
}

/// Changes what `update` names and answers the whole configuration Discord settled on, which
/// is where a level it clamped shows up.
pub fn setVoiceSettings(
    client: *Client,
    io: Io,
    update: *const rpc.VoiceSettings.Update,
) VoiceError!rpc.VoiceSettings {
    try serialize.checkVoiceUpdate(update);

    var settings: rpc.VoiceSettings = .empty;
    _ = try client.accepted(io, .{ .voice_settings = update }, .{ .voice_settings = &settings });
    return settings;
}

/// Sets one user's mix in the local client, and answers what Discord applied.
pub fn setUserVoiceSettings(
    client: *Client,
    io: Io,
    user_id: []const u8,
    settings: *const rpc.UserVoiceSettings,
) VoiceError!rpc.UserVoiceSettings {
    // Named with the settings it belongs to, since nothing about it reached Discord.
    if (user_id.len == 0) return error.InvalidVoiceSettings;
    try serialize.checkUserVoiceSettings(settings);

    var applied: rpc.UserVoiceSettings = .empty;
    _ = try client.accepted(
        io,
        .{ .user_voice_settings = .{ .user_id = user_id, .settings = settings } },
        .{ .user_voice_settings = &applied },
    );
    return applied;
}

/// `InvalidId` is a guild or channel id outside what a Discord id is spelled with.
pub const IdError = AcceptError || error{InvalidId};

/// The guilds the user is in, as many of them as `GuildList.capacity` holds.
pub fn guilds(client: *Client, io: Io, out: *rpc.GuildList) AcceptError!void {
    out.* = .empty;
    _ = try client.accepted(io, .guilds_query, .{ .guilds = out });
}

/// One guild by id. `timeout_seconds` bounds how long Discord takes to gather it, and zero
/// leaves that to Discord.
pub fn guild(
    client: *Client,
    io: Io,
    guild_id: []const u8,
    timeout_seconds: i32,
    out: *rpc.Guild,
) IdError!void {
    try serialize.checkId(guild_id);

    out.* = .empty;
    _ = try client.accepted(io, .{ .guild_query = .{
        .guild_id = guild_id,
        .timeout_seconds = timeout_seconds,
    } }, .{ .guild = out });
}

/// What names each channel of one guild, as many as `ChannelList.capacity` holds.
pub fn channels(client: *Client, io: Io, guild_id: []const u8, out: *rpc.ChannelList) IdError!void {
    try serialize.checkId(guild_id);

    out.* = .empty;
    _ = try client.accepted(
        io,
        .{ .channels_query = .{ .guild_id = guild_id } },
        .{ .channels = out },
    );
}

/// One whole channel by id, with whoever is in it when it carries voice.
pub fn channel(client: *Client, io: Io, channel_id: []const u8, out: *rpc.Channel) IdError!void {
    try serialize.checkId(channel_id);

    out.* = .empty;
    _ = try client.accepted(
        io,
        .{ .channel_query = .{ .channel_id = channel_id } },
        .{ .channel = out },
    );
}

/// The voice channel the user is in. `out.found` says whether they are in one.
pub fn selectedVoiceChannel(client: *Client, io: Io, out: *rpc.Channel) AcceptError!void {
    out.* = .empty;
    _ = try client.accepted(io, .selected_voice_channel_query, .{ .channel = out });
}

/// Puts the user in a voice channel, or takes them out of the one they are in when
/// `channel_id` is null. `out.found` says which of the two happened.
pub fn selectVoiceChannel(
    client: *Client,
    io: Io,
    channel_id: ?[]const u8,
    options: serialize.VoiceSelect,
    out: *rpc.Channel,
) IdError!void {
    if (channel_id) |id| try serialize.checkId(id);

    out.* = .empty;
    _ = try client.accepted(io, .{ .select_voice_channel = .{
        .channel_id = channel_id,
        .options = options,
    } }, .{ .channel = out });
}

/// Brings a text channel up in the Discord window, or leaves the one showing when `channel_id`
/// is null. `out.found` says which of the two happened.
pub fn selectTextChannel(
    client: *Client,
    io: Io,
    channel_id: ?[]const u8,
    timeout_seconds: i32,
    out: *rpc.Channel,
) IdError!void {
    if (channel_id) |id| try serialize.checkId(id);

    out.* = .empty;
    _ = try client.accepted(io, .{ .select_text_channel = .{
        .channel_id = channel_id,
        .timeout_seconds = timeout_seconds,
    } }, .{ .channel = out });
}

/// Offers Discord the devices a manufacturer certifies, in the order it should prefer them.
pub fn setCertifiedDevices(
    client: *Client,
    io: Io,
    devices: []const rpc.CertifiedDevice,
) DeviceError!void {
    try serialize.checkDevices(devices);

    _ = try client.accepted(io, .{ .certified_devices = devices }, null);
}

/// Puts a refusal where `nextEvent` reports it, whether the reader met it or a waiter took
/// the frame that carried it.
fn recordError(client: *Client, io: Io, code: i32, message: Secret) void {
    client.record_mutex.lockUncancelable(io);
    client.last_error.code = code;
    client.last_error.message = message;
    client.record_mutex.unlock(io);

    client.raiseSignal(io, .{ .errored = true });
}

/// Sends a command and waits for the reply carrying its nonce back.
///
/// Discord answers a command exactly once, so the slot is taken for one reply and freed
/// whichever way it ends.
fn call(
    client: *Client,
    io: Io,
    command: Command,
    sink: ?parse.Sink,
    timeout: Io.Timeout,
) RequestError!parse.Frame {
    const nonce = client.nextNonce();
    const slot = try client.reserve(io, nonce, sink);
    errdefer client.release(io, slot);

    if (!try client.enqueue(io, nonce, command)) return error.Disconnected;
    return client.awaitReply(io, slot, timeout);
}

/// Takes a slot for `nonce`, which the reader matches a reply against.
fn reserve(client: *Client, io: Io, nonce: u32, sink: ?parse.Sink) error{RequestsBusy}!u32 {
    assert(nonce > 0);

    client.waiter_mutex.lockUncancelable(io);
    defer client.waiter_mutex.unlock(io);

    for (&client.pending, 0..) |*slot, index| {
        if (slot.state != .free) continue;
        slot.* = .{
            .nonce = nonce,
            .state = .waiting,
            .answer = .empty,
            .sink = sink,
            .malformed = false,
        };
        return @intCast(index);
    }

    return error.RequestsBusy;
}

fn release(client: *Client, io: Io, slot: u32) void {
    assert(slot < client.pending.len);

    client.waiter_mutex.lockUncancelable(io);
    defer client.waiter_mutex.unlock(io);

    client.pending[slot] = .empty;
    assert(client.pending[slot].state == .free);
}

/// Waits for the reader to fill the slot. A reply that never comes leaves on the timeout.
fn awaitReply(
    client: *Client,
    io: Io,
    slot: u32,
    timeout: Io.Timeout,
) RequestError!parse.Frame {
    assert(slot < client.pending.len);
    // Resolved once: each turn of the loop would otherwise restart a duration from scratch.
    const deadline = timeout.toDeadline(io);

    client.waiter_mutex.lockUncancelable(io);
    defer {
        client.pending[slot] = .empty;
        client.waiter_mutex.unlock(io);
    }

    while (true) {
        switch (client.pending[slot].state) {
            .answered => {
                if (client.pending[slot].malformed) return error.BadPayload;
                return client.pending[slot].answer;
            },
            .dropped => return error.Disconnected,
            .free => unreachable,
            .waiting => {},
        }

        client.waiter_condition.waitTimeout(io, &client.waiter_mutex, deadline) catch |err| {
            switch (err) {
                error.Timeout => return error.Disconnected,
                error.Canceled => |e| return e,
            }
        };
    }
}

/// Hands a reply to the request that carries its nonce, answering whether one was waiting.
/// A slot naming a sink is filled here, under the lock its caller clears the slot with, so
/// the storage the sink points at cannot go while this writes to it.
fn deliverReply(client: *Client, io: Io, frame: *const parse.Frame, payload: []const u8) bool {
    assert(frame.has_nonce);
    if (frame.nonce == 0) return false;

    client.waiter_mutex.lockUncancelable(io);
    defer client.waiter_mutex.unlock(io);

    for (&client.pending) |*slot| {
        if (slot.state != .waiting) continue;
        if (slot.nonce != frame.nonce) continue;

        if (slot.sink) |sink| {
            parse.into(sink, payload) catch |err| switch (err) {
                error.BadPayload => slot.malformed = true,
            };
        }

        slot.answer = frame.*;
        slot.state = .answered;
        client.waiter_condition.broadcast(io);
        return true;
    }

    return false;
}

/// Every waiter leaves when the connection does; the reply it waited for is gone with it.
fn dropPending(client: *Client, io: Io) void {
    client.waiter_mutex.lockUncancelable(io);
    defer client.waiter_mutex.unlock(io);

    for (&client.pending) |*slot| {
        if (slot.state == .waiting) slot.state = .dropped;
    }
    client.waiter_condition.broadcast(io);
}

/// Nonces run from one, leaving zero to stand for a reply belonging to no request here.
fn nextNonce(client: *Client) u32 {
    const taken = client.nonce.fetchAdd(1, .monotonic);
    if (taken != 0) return taken;

    // The counter came all the way round. One caller sees the zero, and the one it takes
    // next begins the new run.
    const restarted = client.nonce.fetchAdd(1, .monotonic);
    assert(restarted != 0);
    return restarted;
}

fn raiseSignal(client: *Client, io: Io, signal: Signals) void {
    const mask: u8 = @bitCast(signal);
    assert(@popCount(mask) == 1);
    _ = client.signals.fetchOr(mask, .release);
    client.wakeWaiters(io);
}

/// Taken around the broadcast so a waiter that has looked but not yet waited still sees it.
fn wakeWaiters(client: *Client, io: Io) void {
    client.waiter_mutex.lockUncancelable(io);
    defer client.waiter_mutex.unlock(io);
    client.waiter_condition.broadcast(io);
}

fn takeSignal(client: *Client, signal: Signals) bool {
    const mask: u8 = @bitCast(signal);
    assert(@popCount(mask) == 1);
    const previous = client.signals.fetchAnd(~mask, .acquire);
    return previous & mask != 0;
}

const Command = union(enum) {
    subscription: struct {
        action: serialize.Subscription,
        event: rpc.Event,
        key: Subscription.Key,
    },
    join_reply: struct { user_id: []const u8, reply: Reply },
    authenticate: struct { access_token: []const u8 },
    authorize: struct { scopes: []const []const u8 },
    voice_settings_query,
    voice_settings: *const rpc.VoiceSettings.Update,
    user_voice_settings: struct {
        user_id: []const u8,
        settings: *const rpc.UserVoiceSettings,
    },
    certified_devices: []const rpc.CertifiedDevice,
    guilds_query,
    guild_query: struct { guild_id: []const u8, timeout_seconds: i32 },
    channels_query: struct { guild_id: []const u8 },
    channel_query: struct { channel_id: []const u8 },
    selected_voice_channel_query,
    select_voice_channel: struct {
        channel_id: ?[]const u8,
        options: serialize.VoiceSelect,
    },
    select_text_channel: struct { channel_id: ?[]const u8, timeout_seconds: i32 },

    /// Which buffer this is written into. The voice configuration and the device list carry
    /// enough caller text to outgrow a slab slot.
    fn width(command: Command) enum { slot, bulk } {
        return switch (command) {
            .voice_settings, .certified_devices => .bulk,
            .subscription,
            .join_reply,
            .authenticate,
            .authorize,
            .voice_settings_query,
            .user_voice_settings,
            .guilds_query,
            .guild_query,
            .channels_query,
            .channel_query,
            .selected_voice_channel_query,
            .select_voice_channel,
            .select_text_channel,
            => .slot,
        };
    }
};

/// One request awaiting its reply. `answer` is filled by the reader and read by
/// the caller, both under `waiter_mutex`.
const Pending = struct {
    nonce: u32,
    state: State,
    answer: parse.Frame,
    /// Where the reader puts the part of the reply `answer` has no room for. The waiting
    /// caller owns it, and clears this slot before leaving, both under `waiter_mutex`.
    sink: ?parse.Sink,
    /// Set when the reply arrived and the walk through `sink` could not read it.
    malformed: bool,

    const State = enum {
        /// Open for the next request.
        free,
        /// A caller is waiting on this nonce.
        waiting,
        /// The reader filled `answer`; the caller takes it and frees the slot.
        answered,
        /// The connection went before the reply did.
        dropped,
    };

    const empty: Pending = .{
        .nonce = 0,
        .state = .free,
        .answer = .empty,
        .sink = null,
        .malformed = false,
    };
};

/// Answers whether the command reached the queue; a command that found it full spends no slot.
fn enqueue(client: *Client, io: Io, nonce: u32, command: Command) Error!bool {
    return switch (command.width()) {
        .slot => client.enqueueSlot(io, nonce, command),
        .bulk => client.enqueueBulk(io, nonce, command),
    };
}

/// Lays the command out where the writer will find it, answering its length.
fn writeCommand(client: *Client, payload: []u8, nonce: u32, command: Command) Error!u32 {
    const length = switch (command) {
        .subscription => |change| serialize.subscription(
            payload,
            nonce,
            change.action,
            change.event,
            change.key.slice(),
        ),
        .join_reply => |reply| serialize.joinReply(payload, nonce, reply.user_id, reply.reply),
        .authenticate => |auth| serialize.authenticate(payload, nonce, auth.access_token),
        .authorize => |auth| serialize.authorize(
            payload,
            nonce,
            client.connection.application_id.slice(),
            auth.scopes,
        ),
        .voice_settings_query => serialize.getVoiceSettings(payload, nonce),
        .voice_settings => |update| serialize.setVoiceSettings(payload, nonce, update),
        .user_voice_settings => |mix| serialize.setUserVoiceSettings(
            payload,
            nonce,
            mix.user_id,
            mix.settings,
        ),
        .certified_devices => |devices| serialize.certifiedDevices(payload, nonce, devices),
        .guilds_query => serialize.getGuilds(payload, nonce),
        .guild_query => |query| serialize.getGuild(
            payload,
            nonce,
            query.guild_id,
            query.timeout_seconds,
        ),
        .channels_query => |query| serialize.getChannels(payload, nonce, query.guild_id),
        .channel_query => |query| serialize.getChannel(payload, nonce, query.channel_id),
        .selected_voice_channel_query => serialize.getSelectedVoiceChannel(payload, nonce),
        .select_voice_channel => |select| serialize.selectVoiceChannel(
            payload,
            nonce,
            select.channel_id,
            select.options,
        ),
        .select_text_channel => |select| serialize.selectTextChannel(
            payload,
            nonce,
            select.channel_id,
            select.timeout_seconds,
        ),
    } catch |err| switch (err) {
        error.WriteFailed => return error.PayloadTooLarge,
    };

    assert(length > 0);
    assert(length <= payload.len);
    return length;
}

fn enqueueSlot(client: *Client, io: Io, nonce: u32, command: Command) Error!bool {
    assert(command.width() == .slot);

    client.send_mutex.lockUncancelable(io);
    defer client.send_mutex.unlock(io);

    const slot = client.next_slot;
    assert(slot < slab_slots);
    const slot_bytes = client.outbound_slab[slot * slot_size ..][0..slot_size];

    const length = try client.writeCommand(slot_bytes[Connection.header_size..], nonce, command);
    assert(length <= max_command_size);

    const queued = client.outbound_queue.put(io, &.{.{
        .kind = .command,
        .slot = @intCast(slot),
        .length = @intCast(length),
        .epoch = client.epoch.load(.acquire),
    }}, 0) catch |err| switch (err) {
        error.Closed => return false,
        error.Canceled => |e| return e,
    };
    if (queued == 0) return false;

    client.next_slot = (slot + 1) % slab_slots;
    return true;
}

/// One buffer serves every wide command, so a second caller waits for the writer to be done
/// with the first. `Busy` is what it is told.
fn enqueueBulk(client: *Client, io: Io, nonce: u32, command: Command) Error!bool {
    assert(command.width() == .bulk);

    client.bulk_mutex.lockUncancelable(io);
    if (client.bulk_sending) {
        client.bulk_mutex.unlock(io);
        return false;
    }

    const length = client.writeCommand(
        client.bulk_payload[Connection.header_size..],
        nonce,
        command,
    ) catch |err| {
        client.bulk_mutex.unlock(io);
        return err;
    };
    assert(length <= max_bulk_command_size);

    client.bulk_length = length;
    client.bulk_sending = true;
    client.bulk_mutex.unlock(io);

    const queued = client.outbound_queue.put(io, &.{.{
        .kind = .bulk,
        .slot = 0,
        .length = @intCast(length),
        .epoch = client.epoch.load(.acquire),
    }}, 0) catch |err| switch (err) {
        error.Closed => {
            client.releaseBulk(io);
            return false;
        },
        error.Canceled => |e| {
            client.releaseBulk(io);
            return e;
        },
    };
    if (queued == 0) {
        client.releaseBulk(io);
        return false;
    }
    return true;
}

/// Hands the buffer back, whatever became of the command that held it.
fn releaseBulk(client: *Client, io: Io) void {
    client.bulk_mutex.lockUncancelable(io);
    defer client.bulk_mutex.unlock(io);

    assert(client.bulk_sending);
    client.bulk_sending = false;
    client.bulk_length = 0;
}

fn pumpReads(client: *Client, io: Io, environ: *std.process.Environ.Map) Io.Cancelable!void {
    while (true) {
        if (client.connection.state == .disconnected) {
            client.openConnection(io, environ) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => {
                    try client.waitBeforeRetry(io);
                    continue;
                },
            };
        }

        // Every failure ends the connection, so each one names the code it is reported under.
        const message = client.readMessage(io) catch |err| {
            try client.dropConnection(io, .fromCode(switch (err) {
                error.Canceled => return error.Canceled,
                error.ConnectionClosed => .pipe_closed,
                error.Timeout => .timed_out,
                error.ConcurrencyUnavailable => .unavailable,
                error.BadFrame,
                error.FrameTooLarge,
                error.BadPayload,
                => .read_corrupt,
            }));
            continue;
        };

        client.handleMessage(io, message) catch |err| {
            try client.dropConnection(io, .fromCode(switch (err) {
                error.Canceled => return error.Canceled,
                error.ConnectionClosed => .pipe_closed,
                error.Timeout => .timed_out,
                error.ConcurrencyUnavailable => .unavailable,
                // Reached by echoing a ping whose payload will not fit a frame of its own.
                error.PayloadTooLarge => .read_corrupt,
            }));
        };
    }
}

fn pumpWrites(client: *Client, io: Io) Io.Cancelable!void {
    while (true) {
        const outbound = client.outbound_queue.getOne(io) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => |e| return e,
        };

        assert(outbound.slot < slab_slots);
        assert(outbound.length <= max_command_size);

        client.send(io, outbound) catch |err| switch (err) {
            error.Canceled => |e| return e,
            error.PayloadTooLarge => unreachable,
            // The reader owns reconnection, so a failed send is lost and a presence re-arms.
            else => {},
        };
    }
}

fn openConnection(
    client: *Client,
    io: Io,
    environ: *std.process.Environ.Map,
) Connection.OpenError!void {
    client.write_mutex.lockUncancelable(io);
    defer client.write_mutex.unlock(io);
    assert(client.connection.state == .disconnected);
    try client.connection.open(io, environ);
}

/// A connection that has not greeted us yet is bounded; once greeted, a read waits
/// for the peer's own pace.
fn readMessage(client: *Client, io: Io) Connection.ReadError!Connection.Message {
    assert(client.connection.state != .disconnected);

    const timeout: Io.Timeout = if (client.connection.state == .sent_handshake)
        milliseconds(handshake_timeout_ms)
    else
        .none;

    return client.connection.read(io, &client.chunk_buffer, timeout);
}

fn dropConnection(client: *Client, io: Io, status: Status) Io.Cancelable!void {
    // Only the reader drops a connection, and only one it is holding.
    assert(client.connection.state != .disconnected);

    client.record_mutex.lockUncancelable(io);
    client.last_disconnect = status;
    client.record_mutex.unlock(io);

    client.closeConnection(io);

    assert(!client.isConnected());
    client.dropPending(io);
    client.raiseSignal(io, .{ .disconnected = true });

    try client.waitBeforeRetry(io);
}

fn closeConnection(client: *Client, io: Io) void {
    client.write_mutex.lockUncancelable(io);
    defer client.write_mutex.unlock(io);
    client.connection.close(io);
    client.publishEpoch(false);
    assert(!client.connection.isOpen());
}

fn waitBeforeRetry(client: *Client, io: Io) Io.Cancelable!void {
    const delay_ms = client.backoff.nextDelay();
    assert(delay_ms >= reconnect_min_ms);
    assert(delay_ms <= reconnect_max_ms);

    const delay: Io.Clock.Duration = .{ .raw = .fromMilliseconds(delay_ms), .clock = .awake };
    return delay.sleep(io);
}

/// The wait and the write happen under one hold of the lock, so the connection
/// cannot close between them.
fn send(client: *Client, io: Io, outbound: Outbound) Connection.WriteError!void {
    client.write_mutex.lockUncancelable(io);
    defer client.write_mutex.unlock(io);

    while (!client.connection.isOpen()) {
        try client.connected_condition.wait(io, &client.write_mutex);
    }
    assert(client.connection.isOpen());

    switch (outbound.kind) {
        .command => {
            assert(outbound.slot < slab_slots);
            // Answers something this connection never saw; the resubscription replaces it.
            if (outbound.epoch != client.epoch.load(.acquire)) return;
            assert(outbound.length > 0);
            const frame = client.outbound_slab[outbound.slot * slot_size ..][0..slot_size];
            try client.connection.write(io, .frame, frame, outbound.length);
        },
        .bulk => {
            // Handed back whatever the write did; leaving it held would strand every later
            // caller on the one buffer.
            defer client.releaseBulk(io);

            assert(outbound.slot == 0);
            if (outbound.epoch != client.epoch.load(.acquire)) return;
            assert(outbound.length > 0);
            try client.connection.write(io, .frame, &client.bulk_payload, outbound.length);
        },
        .presence => {
            // Marking the slot pushes the next caller onto the other one; the lock is
            // released before the write, so a stalled peer never holds a caller.
            client.presence_mutex.lockUncancelable(io);
            assert(client.presence_sending == null);
            const claimed = client.presence_latest;
            client.presence_sending = claimed;
            const length = if (claimed) |slot| client.presence_length[slot] else 0;

            // Released inside the hold that took the claim, so a presence stored between the
            // two would otherwise see a marker outstanding and queue nothing.
            client.presence_pending = false;
            client.presence_mutex.unlock(io);

            const slot = claimed orelse return;
            assert(length > 0);
            assert(length <= max_presence_size);

            // Released whatever the write did; leaving it marked would strand every later
            // caller on one buffer.
            defer {
                client.presence_mutex.lockUncancelable(io);
                client.presence_sending = null;
                client.presence_mutex.unlock(io);
            }
            try client.connection.write(io, .frame, &client.presence_payload[slot], length);
        },
    }
}

fn handleMessage(
    client: *Client,
    io: Io,
    message: Connection.Message,
) (Error || Connection.EchoError)!void {
    switch (message) {
        .pong => {},
        .ping => |length| {
            client.write_mutex.lockUncancelable(io);
            defer client.write_mutex.unlock(io);

            // The lock keeps another frame from landing between the pong and its payload.
            try client.connection.echoPong(io, &client.chunk_buffer, length);
        },
        .closed => |frame| try client.handleClose(io, &frame),
        .frame => |payload| try client.handleFrame(
            io,
            &payload.frame,
            client.chunk_buffer[Connection.header_size..][0..payload.length],
        ),
    }
}

/// A close frame is the peer's own account of why it is going away, so its code and message
/// are what the caller is told.
fn handleClose(client: *Client, io: Io, frame: *const parse.Frame) Error!void {
    assert(client.connection.state != .disconnected);
    return client.dropConnection(io, .{ .code = frame.code, .message = frame.message });
}

fn handleFrame(
    client: *Client,
    io: Io,
    frame: *const parse.Frame,
    payload: []const u8,
) Error!void {
    if (client.connection.state == .sent_handshake) return client.handleReady(io, frame);
    assert(client.connection.isOpen());
    return client.handleEvent(io, frame, payload);
}

fn handleReady(client: *Client, io: Io, frame: *const parse.Frame) Error!void {
    assert(client.connection.state == .sent_handshake);

    if (!std.mem.eql(u8, frame.command.slice(), rpc.dispatch)) return;
    if (!std.mem.eql(u8, frame.event.slice(), rpc.ready)) return;

    client.record_mutex.lockUncancelable(io);
    client.connected_user = frame.user;
    client.record_mutex.unlock(io);

    client.write_mutex.lockUncancelable(io);
    client.connection.markConnected();
    client.publishEpoch(true);
    client.connected_condition.broadcast(io);
    client.write_mutex.unlock(io);

    client.backoff.reset();
    client.raiseSignal(io, .{ .connected = true });

    try client.resubscribe(io);

    client.presence_mutex.lockUncancelable(io);
    const has_presence = client.presence_latest != null;
    client.presence_mutex.unlock(io);
    if (has_presence) try client.armPresence(io);
}

/// A nonce marks a response to something this client sent; without one it is an event.
fn handleEvent(
    client: *Client,
    io: Io,
    frame: *const parse.Frame,
    payload: []const u8,
) Io.Cancelable!void {
    assert(client.connection.isOpen());

    // A nonce settles it before the name does: Discord answers a command it accepted with a
    // null event, and that reply still belongs to whoever is waiting on the nonce.
    if (frame.has_nonce) {
        if (client.deliverReply(io, frame, payload)) return;

        if (!std.mem.eql(u8, frame.event.slice(), rpc.errored)) return;
        client.recordError(io, frame.code, frame.message);
        return;
    }

    const name = frame.event.slice();
    if (name.len == 0) return;
    assert(name.len <= parse.text_bytes);

    // Whatever the client never asked for is Discord's to send and this client's to pass over.
    const raised = rpc.Event.fromName(name) orelse return;
    switch (raised) {
        .activity_join => client.recordSecret(io, frame, "join_game_secret", .{
            .join_game = true,
        }),
        .activity_spectate => client.recordSecret(io, frame, "spectate_game_secret", .{
            .spectate_game = true,
        }),
        .activity_join_request => try client.recordJoinRequest(io, frame),
        else => try client.recordNotice(io, raised, payload),
    }
}

/// The payload is walked a second time for what the event carries, which `Frame` has no room
/// for. A walk that fails leaves the event reported with nothing on it, since the event having
/// happened is worth more than the shape it arrived in.
fn recordNotice(
    client: *Client,
    io: Io,
    raised: rpc.Event,
    payload: []const u8,
) Io.Cancelable!void {
    var notice: Notice = .{ .event = raised, .payload = .none };

    // An event that carries nothing needs no walk to find it.
    if (raised.shape() != .none) {
        parse.into(
            .{ .notice = .{ .event = raised, .out = &notice.payload } },
            payload,
        ) catch |err| switch (err) {
            error.BadPayload => notice.payload = .none,
        };
    }

    return client.record(io, Notice, &client.notice_queue, &notice);
}

/// The record is in place before the signal that announces it.
fn recordSecret(
    client: *Client,
    io: Io,
    frame: *const parse.Frame,
    comptime field: []const u8,
    signal: Signals,
) void {
    if (frame.secret.len == 0) return;
    assert(frame.secret.len <= Secret.capacity_bytes);

    client.record_mutex.lockUncancelable(io);
    @field(client, field) = frame.secret;
    client.record_mutex.unlock(io);

    client.raiseSignal(io, signal);
}

fn recordJoinRequest(client: *Client, io: Io, frame: *const parse.Frame) Io.Cancelable!void {
    if (!frame.has_user) return;

    // An id is needed to answer and a name to show, so a request missing either is dropped.
    if (frame.user.id.len == 0) return;
    if (frame.user.username.len == 0) return;

    const requester: User = frame.user;
    assert(requester.id.len > 0);
    assert(requester.username.len > 0);

    return client.record(io, User, &client.join_request_queue, &requester);
}

/// A full queue drops the item: Discord repeats what it reports, on the next invite or the
/// next time the subscribed thing happens.
/// The item is read where it stands, so a record as wide as a notice is copied once.
fn record(
    client: *Client,
    io: Io,
    comptime Item: type,
    queue: *Io.Queue(Item),
    item: *const Item,
) Io.Cancelable!void {
    const one: *const [1]Item = item;
    const queued = queue.put(io, one, 0) catch |err| switch (err) {
        error.Closed => return,
        error.Canceled => |e| return e,
    };
    assert(queued <= 1);
    if (queued == 1) client.wakeWaiters(io);
}

// Raising and taking assert a single bit, so every signal must occupy one of its own.
test "each signal is a distinct single bit" {
    inline for (@typeInfo(Signals).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "unused")) continue;

        var signal: Signals = .{};
        @field(signal, name) = true;
        try std.testing.expectEqual(@as(u8, 1), @popCount(@as(u8, @bitCast(signal))));
    }
}

test "a queued command always fits in a frame" {
    try std.testing.expect(max_command_size <= Connection.max_payload_size);
    try std.testing.expect(max_presence_size <= Connection.max_payload_size);
}

// Every documented field at its limit, built from control characters so every
// byte costs a six-character escape.
test "the largest presence the protocol permits fits its buffer" {
    var fields: [Presence.max_text_bytes]u8 = @splat(0x01);
    const key = fields[0..Presence.max_image_key_bytes];

    // A URL is held to characters that escape to themselves, so its worst case is its length.
    var url: [Presence.max_button_url_bytes]u8 = @splat('u');
    @memcpy(url[0.."https://".len], "https://");
    const button: Presence.Button = .{
        .label = fields[0..Presence.max_button_label_bytes],
        .url = &url,
    };

    comptime assert(Presence.max_url_bytes <= Presence.max_button_url_bytes);
    const link = url[0..Presence.max_url_bytes];

    const presence: Presence = .{
        .state = &fields,
        .details = &fields,
        .state_url = link,
        .details_url = link,
        .status_display_type = .details,
        .start_timestamp = std.math.minInt(i64),
        .end_timestamp = std.math.maxInt(i64),
        .large_image_key = key,
        .large_image_text = &fields,
        .large_image_url = link,
        .small_image_key = key,
        .small_image_text = &fields,
        .small_image_url = link,
        .party_id = &fields,
        .party_size = std.math.maxInt(u32) - 1,
        .party_max = std.math.maxInt(u32),
        .party_privacy = .public,
        .match_secret = &fields,
        .join_secret = &fields,
        .spectate_secret = &fields,
        .instance = true,
        .activity_type = .competing,
        .buttons = &.{ button, button },
    };

    var buffer: [max_presence_size]u8 = undefined;
    const length = try serialize.richPresence(&buffer, std.math.maxInt(u32), 4294967295, &presence);
    try std.testing.expect(length <= max_presence_size);
}

// Every send buffer reserves the header ahead of its payload, so nothing is copied.
test "every send buffer carries room for a frame header" {
    try std.testing.expectEqual(slot_size, Connection.header_size + max_command_size);
    const presence_slots = @FieldType(Client, "presence_payload");
    try std.testing.expectEqual(
        Connection.header_size + max_presence_size,
        @sizeOf(@typeInfo(presence_slots).array.child),
    );

    // A slot per length, so a caller's slot and the writer's cannot be the same one.
    try std.testing.expectEqual(
        @typeInfo(presence_slots).array.len,
        @typeInfo(@FieldType(Client, "presence_length")).array.len,
    );
    // The chunk holds a payload whole, and a staged pong behind its header.
    try std.testing.expectEqual(chunk_bytes, @sizeOf(@FieldType(Client, "chunk_buffer")));
    try std.testing.expect(chunk_bytes >= Connection.max_payload_size);
    try std.testing.expect(chunk_bytes >= Connection.header_size + Connection.max_payload_size);
}

// The slab is sized for commands alone, which holds only while the widest still fits.
test "the widest command fits one slab slot" {
    var buffer: [max_command_size]u8 = undefined;
    const widest_nonce = std.math.maxInt(u32);

    // A peer-supplied id, escaped, is the widest a join reply serialises to.
    const user_id: [User.capacityOf("id")]u8 = @splat(0x01);
    const replied = try serialize.joinReply(&buffer, widest_nonce, &user_id, .yes);
    try std.testing.expect(replied <= max_command_size);

    const query = try serialize.getVoiceSettings(&buffer, widest_nonce);
    try std.testing.expect(query <= max_command_size);

    // Every field at its limit, and the pan and volume Discord will take.
    const mix: rpc.UserVoiceSettings = .{
        .pan_left = -0.123456789,
        .pan_right = 0.987654321,
        .volume = rpc.UserVoiceSettings.volume_max,
        .mute = true,
    };
    try serialize.checkUserVoiceSettings(&mix);
    const applied = try serialize.setUserVoiceSettings(&buffer, widest_nonce, &user_id, &mix);
    try std.testing.expect(applied <= max_command_size);

    const key: [rpc.snowflake_bytes]u8 = @splat('9');

    // The widest id Discord spells, on every command that names one.
    try serialize.checkId(&key);
    const widest_timeout = std.math.maxInt(i32);
    for ([_]u32{
        try serialize.getGuilds(&buffer, widest_nonce),
        try serialize.getSelectedVoiceChannel(&buffer, widest_nonce),
        try serialize.getGuild(&buffer, widest_nonce, &key, widest_timeout),
        try serialize.getChannels(&buffer, widest_nonce, &key),
        try serialize.getChannel(&buffer, widest_nonce, &key),
        try serialize.selectVoiceChannel(&buffer, widest_nonce, &key, .{
            .timeout_seconds = widest_timeout,
            .force = true,
            .navigate = true,
        }),
        try serialize.selectTextChannel(&buffer, widest_nonce, &key, widest_timeout),
    }) |length| try std.testing.expect(length <= max_command_size);

    // The longest event name Discord spells, keyed by the widest id it can be scoped to.
    for (std.enums.values(rpc.Event)) |raised| {
        const scoped = raised.scope() != .global;
        const subscribed = try serialize.subscription(
            &buffer,
            widest_nonce,
            .unsubscribe,
            raised,
            if (scoped) &key else "",
        );
        try std.testing.expect(subscribed <= max_command_size);
    }
}

// The bulk buffer is sized from the capacities alone, which holds only while the widest each
// of them permits still fits.
test "the widest wide command fits the bulk buffer" {
    var buffer: [max_bulk_command_size]u8 = undefined;
    const widest_nonce = std.math.maxInt(u32);

    // Control characters are valid UTF-8 and cost a six-character escape apiece, which is the
    // worst a device id or a key name can do.
    const device_id: [rpc.VoiceSettings.device_bytes]u8 = @splat(0x01);
    var key: rpc.VoiceSettings.Shortcut = .{
        .kind = std.math.minInt(i32),
        .code = std.math.minInt(i32),
    };
    const key_name: [rpc.VoiceSettings.key_name_bytes]u8 = @splat(0x01);
    key.name.set(&key_name);

    const keys: [rpc.VoiceSettings.shortcut_capacity]rpc.VoiceSettings.Shortcut = @splat(key);
    const update: rpc.VoiceSettings.Update = .{
        .input_device_id = &device_id,
        .input_volume = -1.2345678,
        .output_device_id = &device_id,
        .output_volume = -1.2345678,
        .mode = .push_to_talk,
        .mode_auto_threshold = true,
        .mode_threshold = -1.2345678,
        .mode_delay = -1.2345678,
        .shortcut = &keys,
        .automatic_gain_control = true,
        .echo_cancellation = true,
        .noise_suppression = true,
        .qos = true,
        .silence_warning = true,
        .deaf = true,
        .mute = true,
    };
    try serialize.checkVoiceUpdate(&update);
    const settings = try serialize.setVoiceSettings(&buffer, widest_nonce, &update);
    try std.testing.expect(settings <= max_bulk_command_size);

    // Device text escapes to itself, so its length is its cost.
    const text_bytes = rpc.CertifiedDevice.text_bytes;
    const filled: [text_bytes]u8 = @splat('d');
    const related: [rpc.CertifiedDevice.related_capacity][]const u8 = @splat(&filled);
    const device: rpc.CertifiedDevice = .{
        .kind = .audio_output,
        .id = &filled,
        .vendor_name = &filled,
        .vendor_url = &filled,
        .model_name = &filled,
        .model_url = &filled,
        .related = &related,
        .echo_cancellation = true,
        .noise_suppression = true,
        .automatic_gain_control = true,
        .hardware_mute = true,
    };
    const devices: [rpc.CertifiedDevice.capacity]rpc.CertifiedDevice = @splat(device);
    try serialize.checkDevices(&devices);
    const offered = try serialize.certifiedDevices(&buffer, widest_nonce, &devices);
    try std.testing.expect(offered <= max_bulk_command_size);
}

test "the epoch's parity is the connection's liveness, and each connection gets its own" {
    const client = try std.testing.allocator.create(Client);
    defer std.testing.allocator.destroy(client);

    client.init(.{ .application_id = "111111111111111111" });
    try std.testing.expect(!client.isConnected());

    client.publishEpoch(true);
    try std.testing.expect(client.isConnected());
    const first = client.epoch.load(.acquire);

    // Publishing a state already in force leaves the epoch where it is.
    client.publishEpoch(true);
    try std.testing.expectEqual(first, client.epoch.load(.acquire));

    client.publishEpoch(false);
    try std.testing.expect(!client.isConnected());
    client.publishEpoch(false);
    try std.testing.expect(!client.isConnected());

    client.publishEpoch(true);
    try std.testing.expect(client.isConnected());
    try std.testing.expect(client.epoch.load(.acquire) != first);
}

test "an application id too long for the handshake is refused" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();

    const client = try gpa.create(Client);
    defer gpa.destroy(client);

    // An id stored short would connect as a different application.
    const long: [128]u8 = @splat('1');
    client.init(.{ .application_id = &long });
    try std.testing.expectError(error.InvalidApplicationId, client.start(io, &environ));

    client.init(.{ .application_id = "" });
    try std.testing.expectError(error.InvalidApplicationId, client.start(io, &environ));
}

// Zero marks a reply belonging to no request, so the counter coming round has to step over it.
test "the nonce counter never hands out zero" {
    const gpa = std.testing.allocator;

    const client = try gpa.create(Client);
    defer gpa.destroy(client);
    client.init(.{ .application_id = "111111111111111111" });

    try std.testing.expectEqual(@as(u32, 1), client.nextNonce());

    // One short of the wrap, so the next two cross it.
    client.nonce.store(std.math.maxInt(u32), .monotonic);
    try std.testing.expectEqual(std.math.maxInt(u32), client.nextNonce());
    try std.testing.expectEqual(@as(u32, 1), client.nextNonce());
}

test "a subscription is the event and the key together" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const client = try gpa.create(Client);
    defer gpa.destroy(client);
    client.init(.{ .application_id = "111111111111111111" });

    try client.subscribe(io, .message_create, "333333333333333333");
    try std.testing.expect(client.isSubscribed(io, .message_create, "333333333333333333"));

    // The same event on another channel is another subscription.
    try std.testing.expect(!client.isSubscribed(io, .message_create, "444444444444444444"));
    try std.testing.expect(!client.isSubscribed(io, .message_update, "333333333333333333"));

    // Nothing has been sent, so giving it back frees the entry outright.
    try client.unsubscribe(io, .message_create, "333333333333333333");
    try std.testing.expect(!client.isSubscribed(io, .message_create, "333333333333333333"));
    for (&client.subscriptions) |entry| try std.testing.expectEqual(null, entry.event);
}

test "a key the scope has no argument for is refused" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const client = try gpa.create(Client);
    defer gpa.destroy(client);
    client.init(.{ .application_id = "111111111111111111" });

    const wide: [rpc.snowflake_bytes + 1]u8 = @splat('3');
    try std.testing.expectError(
        error.InvalidSubscription,
        client.subscribe(io, .activity_join, "333333333333333333"),
    );
    try std.testing.expectError(
        error.InvalidSubscription,
        client.subscribe(io, .guild_status, ""),
    );
    try std.testing.expectError(
        error.InvalidSubscription,
        client.subscribe(io, .message_create, &wide),
    );

    // A refusal records nothing, so the table is untouched.
    for (&client.subscriptions) |entry| try std.testing.expectEqual(null, entry.event);
}

test "the subscription table is bounded" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const client = try gpa.create(Client);
    defer gpa.destroy(client);
    client.init(.{ .application_id = "111111111111111111" });

    var taken: u32 = 0;
    while (taken < subscription_capacity) : (taken += 1) {
        var key: [rpc.snowflake_bytes]u8 = @splat('0');
        _ = std.fmt.printInt(&key, taken, 10, .lower, .{ .width = key.len, .fill = '0' });
        try client.subscribe(io, .message_create, &key);
    }

    try std.testing.expectError(
        error.SubscriptionsFull,
        client.subscribe(io, .activity_join, ""),
    );
}

test "a reply reaches the request that carries its nonce" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const client = try gpa.create(Client);
    defer gpa.destroy(client);
    client.init(.{ .application_id = "111111111111111111" });

    const slot = try client.reserve(io, 7, null);

    var reply: parse.Frame = .empty;
    reply.has_nonce = true;
    reply.nonce = 7;
    reply.code = 4009;

    try std.testing.expect(client.deliverReply(io, &reply, "{}"));

    // Already answered, so the wait returns without one.
    const answer = try client.awaitReply(io, slot, .none);
    try std.testing.expectEqual(@as(i32, 4009), answer.code);

    // The slot is open again once its caller has taken the reply.
    const reused = try client.reserve(io, 8, null);
    try std.testing.expectEqual(slot, reused);
}

test "a reply wider than a frame is walked into the waiting caller's own storage" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const client = try gpa.create(Client);
    defer gpa.destroy(client);
    client.init(.{ .application_id = "111111111111111111" });

    var settings: rpc.VoiceSettings = .empty;
    const slot = try client.reserve(io, 11, .{ .voice_settings = &settings });

    var reply: parse.Frame = .empty;
    reply.has_nonce = true;
    reply.nonce = 11;

    const payload =
        \\{"cmd":"GET_VOICE_SETTINGS","nonce":"11","data":{"mute":true,"input":{"volume":40}}}
    ;
    try std.testing.expect(client.deliverReply(io, &reply, payload));

    _ = try client.awaitReply(io, slot, .none);
    try std.testing.expect(settings.mute);
    try std.testing.expectEqual(@as(f32, 40), settings.input.volume);
}

test "a reply the second walk cannot read reaches its caller as a bad payload" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const client = try gpa.create(Client);
    defer gpa.destroy(client);
    client.init(.{ .application_id = "111111111111111111" });

    var settings: rpc.VoiceSettings = .empty;
    const slot = try client.reserve(io, 12, .{ .voice_settings = &settings });

    var reply: parse.Frame = .empty;
    reply.has_nonce = true;
    reply.nonce = 12;

    // The reply is still delivered: the slot has to be freed for its caller either way.
    try std.testing.expect(client.deliverReply(io, &reply, "{\"data\":{"));
    try std.testing.expectError(error.BadPayload, client.awaitReply(io, slot, .none));
}

test "a reply for a nonce nobody waits on is left to the reader" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const client = try gpa.create(Client);
    defer gpa.destroy(client);
    client.init(.{ .application_id = "111111111111111111" });

    var reply: parse.Frame = .empty;
    reply.has_nonce = true;
    reply.nonce = 99;
    try std.testing.expect(!client.deliverReply(io, &reply, "{}"));

    // A nonce this client never wrote reads back as zero, which matches nothing.
    _ = try client.reserve(io, 5, null);
    reply.nonce = 0;
    try std.testing.expect(!client.deliverReply(io, &reply, "{}"));
}

test "every slot held answers the next request with room to retry" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const client = try gpa.create(Client);
    defer gpa.destroy(client);
    client.init(.{ .application_id = "111111111111111111" });

    var taken: u32 = 0;
    while (taken < request_capacity) : (taken += 1) _ = try client.reserve(io, taken + 1, null);
    try std.testing.expectError(error.RequestsBusy, client.reserve(io, 100, null));

    client.release(io, 0);
    _ = try client.reserve(io, 100, null);
}

test "a connection going leaves every waiter with an answer" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const client = try gpa.create(Client);
    defer gpa.destroy(client);
    client.init(.{ .application_id = "111111111111111111" });

    const slot = try client.reserve(io, 3, null);
    client.dropPending(io);

    try std.testing.expectError(error.Disconnected, client.awaitReply(io, slot, .none));
}

test "stopping a client that never started is nothing to do" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const client = try gpa.create(Client);
    defer gpa.destroy(client);

    client.init(.{ .application_id = "111111111111111111" });
    client.stop(io);
    client.stop(io);
    try std.testing.expect(!client.isRunning());
}
