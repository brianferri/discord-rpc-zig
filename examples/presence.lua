-- The same counter as send_presence.zig, driven through the C ABI from LuaJIT.
--
--   zig build
--   luajit examples/presence.lua [path to the shared library]

local ffi = require("ffi")

ffi.cdef [[
typedef struct {
    uint64_t opaque[2];
} DiscordClient;

typedef struct {
    const char *user_id;
    const char *username;
    const char *discriminator;
    const char *avatar;
} DiscordUser;

typedef struct {
    int kind;
    int code;
    int subscribed;
    int shape;
    const char *message;
    const char *secret;
    DiscordUser user;
    const char *channel_id;
    const char *guild_id;
    const char *name;
    const char *title;
    const char *body;
} DiscordEvent;

typedef struct {
    const char *label;
    const char *url;
} DiscordButton;

typedef struct {
    const char *state;
    const char *details;
    const char *state_url;
    const char *details_url;
    int status_display;
    int64_t start_timestamp;
    int64_t end_timestamp;
    const char *large_image_key;
    const char *large_image_text;
    const char *large_image_url;
    const char *small_image_key;
    const char *small_image_text;
    const char *small_image_url;
    const char *party_id;
    int party_size;
    int party_max;
    int party_privacy;
    const char *match_secret;
    const char *join_secret;
    const char *spectate_secret;
    signed char instance;
    int kind;
    const DiscordButton *buttons;
    int button_count;
} DiscordRichPresence;

int discord_client_init(DiscordClient *, const char *, const char *const *,
                        bool, const char *);
int discord_client_deinit(DiscordClient *);
int discord_client_start(DiscordClient *);
int discord_client_stop(DiscordClient *);
int discord_client_is_running(DiscordClient *, bool *);
int discord_client_subscribe(DiscordClient *, int, const char *);
int discord_client_unsubscribe(DiscordClient *, int, const char *);
int discord_client_is_subscribed(DiscordClient *, int, const char *, bool *);
int discord_client_set_presence(DiscordClient *, const DiscordRichPresence *);
int discord_client_clear_presence(DiscordClient *);
int discord_client_respond(DiscordClient *, const char *, int);
int discord_client_next_event(DiscordClient *, DiscordEvent *, int timeout_ms);
]]

---@class DiscordRichPresence
---@field state string
---@field details string
---@field state_url string
---@field details_url string
---@field status_display integer
---@field start_timestamp integer
---@field end_timestamp integer
---@field large_image_key string
---@field large_image_text string
---@field large_image_url string
---@field small_image_key string
---@field small_image_text string
---@field small_image_url string
---@field party_id string
---@field party_size integer
---@field party_max integer
---@field party_privacy integer
---@field match_secret string
---@field join_secret string
---@field spectate_secret string
---@field instance integer
---@field kind integer
---@field buttons ffi.cdata*
---@field button_count integer

-- Values are part of the ABI contract; src/c.zig is where they are defined.
local INIT_STATUS = {
    [0] = "success",
    [1] = "unexpected",
    [2] = "out of memory",
    [3] = "application id is invalid",
    [4] = "system resources are unavailable",
    [5] = "registration was declined",
    [6] = "canceled",
    [7] = "client handle is invalid",
}

local CLIENT_STATUS = {
    [0] = "ok",
    [1] = "client handle is invalid",
    [2] = "presence is invalid",
    [3] = "payload is too large",
    [4] = "canceled",
    [5] = "empty",
    [6] = "busy",
    [7] = "disconnected",
    [8] = "refused",
}

local OK, EMPTY = 0, 5
local KIND_PLAYING = 0
local REPLY_YES = 1

-- The three a game is invited through. src/c.zig numbers the whole catalogue.
local ACTIVITY_JOIN, ACTIVITY_SPECTATE, ACTIVITY_JOIN_REQUEST = 17, 18, 19

local application_id = "1111111111111111111"

local default_paths = {
    Linux = "zig-out/lib/libdiscord-rpc-c.so",
    OSX = "zig-out/lib/libdiscord-rpc-c.dylib",
    Windows = "zig-out/bin/discord-rpc-c.dll",
}

local discord = ffi.load(arg[1] or default_paths[jit.os] or default_paths.Linux)

local function check(what, names, status)
    if status ~= OK then
        error(string.format("%s: %s (%d)", what, names[status] or "unknown", status), 2)
    end
end

local function text(pointer)
    if pointer == nil then return nil end
    return ffi.string(pointer)
end

-- An array so the cdata carries a pointer the calls can take.
local client = ffi.new("DiscordClient[1]")
local event = ffi.new("DiscordEvent[1]")

local handlers = {
    [0] = function(e)
        print(string.format("connected to %s#%s - %s",
            text(e.user.username), text(e.user.discriminator), text(e.user.user_id)))
    end,
    [1] = function(e) print(string.format("disconnected (%d: %s)", e.code, text(e.message))) end,
    [2] = function(e) print(string.format("error (%d: %s)", e.code, text(e.message))) end,
    [3] = function(e) print(string.format("join (%s)", text(e.secret))) end,
    [4] = function(e) print(string.format("spectate (%s)", text(e.secret))) end,
    [5] = function(e)
        print(string.format("join request from %s - accepting", text(e.user.username)))
        check("respond", CLIENT_STATUS,
            discord.discord_client_respond(client, e.user.user_id, REPLY_YES))
    end,
    [6] = function(e)
        print(string.format("subscribed event %d fired (shape %d)", e.subscribed, e.shape))
    end,
}

-- Takes everything ready, waiting up to `timeout_ms` for the first one.
local function drain(timeout_ms)
    local wait = timeout_ms
    while true do
        local status = discord.discord_client_next_event(client, event, wait)
        if status == EMPTY then return end
        check("next_event", CLIENT_STATUS, status)
        handlers[event[0].kind](event[0])
        wait = 0
    end
end

-- A nil environment takes the one this process was started with.
check("init", INIT_STATUS,
    discord.discord_client_init(client, application_id, nil, false, nil))

-- A nil key is what the globally-watched events take.
for _, subscribed in ipairs({ ACTIVITY_JOIN, ACTIVITY_SPECTATE, ACTIVITY_JOIN_REQUEST }) do
    check("subscribe", CLIENT_STATUS,
        discord.discord_client_subscribe(client, subscribed, nil))
end

local subscribed = ffi.new("bool[1]")
check("is_subscribed", CLIENT_STATUS,
    discord.discord_client_is_subscribed(client, ACTIVITY_JOIN, nil, subscribed))
print("subscribed to ACTIVITY_JOIN: " .. tostring(subscribed[0]))

local presence = ffi.new("DiscordRichPresence") --[[@as DiscordRichPresence]]
presence.state = "state-1"
presence.start_timestamp = os.time()
presence.large_image_key = "image-1"
presence.small_image_key = "image-2"
presence.party_id = "party-1"
presence.party_size = 1
presence.party_max = 6
presence.party_privacy = 1
presence.kind = KIND_PLAYING

-- Held in a variable, because the presence keeps a pointer to it.
local buttons = ffi.new("DiscordButton[2]", {
    { label = "label-1", url = "https://example.invalid/one" },
    { label = "label-2", url = "https://example.invalid/two" },
})
presence.buttons = buttons
presence.button_count = 2

for counter = 1, 5 do
    presence.details = "Counter: " .. counter
    check("set_presence", CLIENT_STATUS, discord.discord_client_set_presence(client, presence))
    print("counter is now " .. counter)
    drain(1000)
end

-- Pausing keeps the handle, so starting again costs no rebuild.
check("stop", CLIENT_STATUS, discord.discord_client_stop(client))
local running = ffi.new("bool[1]")
check("is_running", CLIENT_STATUS, discord.discord_client_is_running(client, running))
print("running after stop: " .. tostring(running[0]))
check("start", INIT_STATUS, discord.discord_client_start(client))

check("unsubscribe", CLIENT_STATUS,
    discord.discord_client_unsubscribe(client, ACTIVITY_SPECTATE, nil))

check("clear_presence", CLIENT_STATUS, discord.discord_client_clear_presence(client))
drain(0)
check("deinit", CLIENT_STATUS, discord.discord_client_deinit(client))
