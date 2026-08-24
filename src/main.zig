const r4os = @import("r4os");
const opl3 = @import("engine.zig");

var engine_sends: u64 = 0;
var engine_renders: u64 = 0;
var engine_stops: u64 = 0;
var engine_errors: u64 = 0;
var engine_last_result: i32 = 0;
var engine: r4os.abi.SynthEngine = .{};

comptime {
    asm (r4os.r4dev.driverEntriesAsm("opl3_init", "opl3_shutdown"));
}

export fn opl3_init(api: *const r4os.r4dev.DriverApi) callconv(.c) i32 {
    var ctx = r4os.r4dev.DriverContext.init(api);
    ctx.logInfo("OPL3 synth engine init");
    opl3.reset();
    opl3.configureDefaultPatch();
    engine = .{
        .flags = r4os.abi.synth_engine_flag_midi | r4os.abi.synth_engine_flag_opl3,
        .midi_send = opl3MidiSend,
        .render_pcm = opl3RenderPcm,
        .stop = opl3Stop,
        .status = opl3Status,
        .opl3_reset = opl3Reset,
        .opl3_write_register = opl3WriteRegister,
    };
    if (ctx.registerSynthEngineEx("OPL3", &engine) != 0) return -1;
    return 0;
}

export fn opl3_shutdown() callconv(.c) i32 {
    return 0;
}

fn opl3MidiSend(context: ?*anyopaque, channel: u8, status: u8, data1: u8, data2: u8) callconv(.c) i32 {
    _ = context;
    const event = status & 0xF0;
    switch (event) {
        0x80 => opl3.midiNoteOff(data1, channel),
        0x90 => {
            if (data2 == 0) {
                opl3.midiNoteOff(data1, channel);
            } else {
                opl3.midiNoteOn(data1, data2, channel);
            }
        },
        0xB0 => opl3.midiControlChange(channel, data1, data2),
        0xC0 => opl3.midiProgramChange(channel, data1),
        else => {},
    }
    engine_sends +%= 1;
    engine_last_result = 0;
    return 0;
}

fn opl3RenderPcm(context: ?*anyopaque, out: [*]u8, capacity: u32, rate: u32, channels: u16, format: u16) callconv(.c) i32 {
    _ = context;
    if (rate != opl3.SAMPLE_RATE or channels != 2 or format != @intFromEnum(r4os.abi.AudioFormat.s16le)) return r4os.abi.service_api_result_invalid;
    if (capacity == 0 or capacity > opl3.RENDER_BYTES or (capacity % 4) != 0) return r4os.abi.service_api_result_invalid;
    const frames: usize = capacity / 4;
    _ = opl3.renderFrames(out[0..capacity], frames);
    engine_renders +%= 1;
    engine_last_result = 0;
    return @intCast(capacity);
}

fn opl3Stop(context: ?*anyopaque) callconv(.c) i32 {
    _ = context;
    opl3.allNotesOff();
    engine_stops +%= 1;
    engine_last_result = 0;
    return 0;
}

fn opl3Reset(context: ?*anyopaque) callconv(.c) i32 {
    _ = context;
    opl3.reset();
    opl3.configureDefaultPatch();
    engine_last_result = 0;
    return 0;
}

fn opl3WriteRegister(context: ?*anyopaque, bank: u8, register: u8, value: u8) callconv(.c) i32 {
    _ = context;
    const result = opl3.writeRegister(bank, register, value);
    engine_last_result = result;
    if (result < 0) engine_errors +%= 1;
    return result;
}

fn opl3Status(context: ?*anyopaque, out: *r4os.abi.SynthEngineStatus) callconv(.c) i32 {
    _ = context;
    out.* = .{
        .active = 1,
        .sends = engine_sends,
        .renders = engine_renders,
        .stops = engine_stops,
        .errors = engine_errors,
        .last_result = engine_last_result,
    };
    return 0;
}
