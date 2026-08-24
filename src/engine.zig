const k = struct {
    fn puts(_: []const u8) void {}
    fn putDec(_: anytype) void {}
    fn putHex(_: anytype, _: u8) void {}
    fn putc(_: u8) void {}
};

const REGISTER_COUNT: usize = 512;
const OPERATOR_COUNT: usize = 36;
const CHANNEL_COUNT: usize = 18;
pub const RENDER_FRAMES: usize = 1024;
pub const RENDER_BYTES: usize = RENDER_FRAMES * 4;
pub const SAMPLE_RATE: u32 = 48_000;
const MIDI_CHANNEL_COUNT: usize = 16;
const NOTE_RELEASE_FRAMES: u16 = 4_800;

const operator_offsets = [_]u8{
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05,
    0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15,
};

const sine_quarter = [_]i32{
    0,     1608,  3212,  4808,  6393,  7962,  9512,  11039,
    12539, 14010, 15446, 16846, 18204, 19519, 20787, 22005,
    23170, 24279, 25329, 26319, 27245, 28105, 28898, 29621,
    30273, 30852, 31356, 31785, 32137, 32412, 32609, 32728,
    32767,
};

const mod_offsets = [_]u8{ 0x00, 0x01, 0x02, 0x08, 0x09, 0x0A, 0x10, 0x11, 0x12 };
const car_offsets = [_]u8{ 0x03, 0x04, 0x05, 0x0B, 0x0C, 0x0D, 0x13, 0x14, 0x15 };

const Operator = struct {
    multiple: u8 = 0,
    tremolo: bool = false,
    vibrato: bool = false,
    sustain_sound: bool = false,
    key_scale_rate: bool = false,
    key_scale_level: u8 = 0,
    total_level: u8 = 0,
    attack: u8 = 0,
    decay: u8 = 0,
    sustain_level: u8 = 0,
    release: u8 = 0,
    waveform: u8 = 0,
    phase: u32 = 0,
    envelope: u16 = 0,
    age_frames: u64 = 0,
};

const Channel = struct {
    fnum: u16 = 0,
    block: u8 = 0,
    key_on: bool = false,
    midi_note: u8 = 0xFF,
    midi_velocity: u8 = 0,
    midi_channel: u8 = 0xFF,
    release_frames: u16 = 0,
    feedback: u8 = 0,
    algorithm: u8 = 0,
    pan_left: bool = false,
    pan_right: bool = false,
    mod_operator: usize = 0,
    car_operator: usize = 0,
    feedback_prev: i32 = 0,
    feedback_last: i32 = 0,
};

const MidiChannelState = struct {
    program: u8 = 0,
    volume: u8 = 100,
    expression: u8 = 127,
    pan: u8 = 64,
};

const Patch = struct {
    mod_mul: u8,
    car_mul: u8,
    mod_tl: u8,
    car_tl: u8,
    mod_ad: u8,
    car_ad: u8,
    mod_sr: u8,
    car_sr: u8,
    mod_wave: u8,
    car_wave: u8,
    alg: u8,
    feedback: u8,
};

var registers: [REGISTER_COUNT]u8 = .{0} ** REGISTER_COUNT;
var operators: [OPERATOR_COUNT]Operator = .{Operator{}} ** OPERATOR_COUNT;
var channels: [CHANNEL_COUNT]Channel = .{Channel{}} ** CHANNEL_COUNT;
var writes: u64 = 0;
var last_bank: u8 = 0;
var last_register: u8 = 0;
var last_value: u8 = 0;
var opl3_enabled: bool = false;
var rhythm_enabled: bool = false;
var rhythm_bits: u8 = 0;
var four_op_mask: u8 = 0;
var noise_state: u32 = 0x1234_ABCD;
var waveform_select_enabled: bool = false;
var render_blocks: u64 = 0;
var render_frames: u64 = 0;
var last_render_channel: u8 = 0;
var last_render_sample: i16 = 0;
var last_left_sample: i16 = 0;
var last_right_sample: i16 = 0;
var last_mixed_channels: u8 = 0;
var midi_note_events: u64 = 0;
var voice_steals: u64 = 0;
var midi_channels: [MIDI_CHANNEL_COUNT]MidiChannelState = .{MidiChannelState{}} ** MIDI_CHANNEL_COUNT;
var midi_program_changes: u64 = 0;
var midi_control_changes: u64 = 0;

pub fn reset() void {
    registers = .{0} ** REGISTER_COUNT;
    operators = .{Operator{}} ** OPERATOR_COUNT;
    channels = .{Channel{}} ** CHANNEL_COUNT;
    writes = 0;
    last_bank = 0;
    last_register = 0;
    last_value = 0;
    opl3_enabled = false;
    rhythm_enabled = false;
    rhythm_bits = 0;
    four_op_mask = 0;
    noise_state = 0x1234_ABCD;
    waveform_select_enabled = false;
    render_blocks = 0;
    render_frames = 0;
    last_render_channel = 0;
    last_render_sample = 0;
    last_left_sample = 0;
    last_right_sample = 0;
    last_mixed_channels = 0;
    midi_note_events = 0;
    voice_steals = 0;
    midi_channels = .{MidiChannelState{}} ** MIDI_CHANNEL_COUNT;
    midi_program_changes = 0;
    midi_control_changes = 0;
    initChannelOperators();
}

pub fn writeRegister(bank: u8, reg: u8, value: u8) i32 {
    if (bank > 1) return -1;
    const index: usize = (@as(usize, bank) * 256) + reg;
    registers[index] = value;
    writes += 1;
    last_bank = bank;
    last_register = reg;
    last_value = value;
    decodeGlobal(bank, reg, value);
    decodeOperator(bank, reg, value);
    decodeChannel(bank, reg, value);
    return 0;
}

pub fn runRegisterDemo() void {
    reset();

    _ = writeRegister(1, 0x05, 0x01); // OPL3 enable
    _ = writeRegister(0, 0x01, 0x20); // waveform select enable

    // Channel 0, operator pair 0/3. This resembles a basic AdLib voice setup.
    _ = writeRegister(0, 0x20, 0x21);
    _ = writeRegister(0, 0x23, 0x01);
    _ = writeRegister(0, 0x40, 0x18);
    _ = writeRegister(0, 0x43, 0x00);
    _ = writeRegister(0, 0x60, 0xF3);
    _ = writeRegister(0, 0x63, 0xF3);
    _ = writeRegister(0, 0x80, 0x77);
    _ = writeRegister(0, 0x83, 0x77);
    _ = writeRegister(0, 0xE0, 0x00);
    _ = writeRegister(0, 0xE3, 0x00);
    _ = writeRegister(0, 0xA0, 0x98);
    _ = writeRegister(0, 0xB0, 0x31);
    _ = writeRegister(0, 0xC0, 0x31);
}

pub fn renderBlock(out: []u8) bool {
    return renderFrames(out, RENDER_FRAMES);
}

pub fn renderFrames(out: []u8, frame_count: usize) bool {
    if (frame_count == 0 or frame_count > RENDER_FRAMES or out.len < frame_count * 4) return false;

    var frame: usize = 0;
    while (frame < frame_count) : (frame += 1) {
        var left: i32 = 0;
        var right: i32 = 0;
        var mixed_channels: u8 = 0;

        var ch_index: usize = 0;
        while (ch_index < channels.len) : (ch_index += 1) {
            const ch = &channels[ch_index];
            if ((!ch.key_on and ch.release_frames == 0) or ch.fnum == 0) continue;
            const sample = renderChannelSample(ch);
            const pan_left = ch.pan_left or (!ch.pan_left and !ch.pan_right);
            const pan_right = ch.pan_right or (!ch.pan_left and !ch.pan_right);
            if (pan_left) left += sample;
            if (pan_right) right += sample;
            mixed_channels += 1;
            last_render_channel = @intCast(ch_index);
        }

        if (rhythm_enabled) {
            const rhythm = renderRhythmSample();
            left += rhythm.left;
            right += rhythm.right;
            if (rhythm.active) mixed_channels += 1;
        }

        const divisor = mixDivisor(mixed_channels);
        const left_sample = clampI16(@divTrunc(left, divisor));
        const right_sample = clampI16(@divTrunc(right, divisor));
        const left_bits: u16 = @bitCast(left_sample);
        const right_bits: u16 = @bitCast(right_sample);
        const off = frame * 4;
        out[off] = @intCast(left_bits & 0x00FF);
        out[off + 1] = @intCast((left_bits >> 8) & 0x00FF);
        out[off + 2] = @intCast(right_bits & 0x00FF);
        out[off + 3] = @intCast((right_bits >> 8) & 0x00FF);
        last_render_sample = left_sample;
        last_left_sample = left_sample;
        last_right_sample = right_sample;
        last_mixed_channels = mixed_channels;
    }

    if (last_mixed_channels == 0) return false;
    render_blocks += 1;
    render_frames += frame_count;
    return true;
}

pub fn configureDefaultPatch() void {
    _ = writeRegister(1, 0x05, 0x01);
    _ = writeRegister(0, 0x01, 0x20);
    _ = writeRegister(0, 0xBD, 0x00);
}

pub fn midiNoteOn(note: u8, velocity: u8, midi_channel: u8) void {
    if (velocity == 0) {
        midiNoteOff(note, midi_channel);
        return;
    }
    configureDefaultPatch();
    const state = midi_channels[midi_channel & 0x0F];
    const patch = patchForMidi(midi_channel, state.program, note);
    const routed_note = noteForMidi(midi_channel, note);
    const ch_index = allocateVoice(note, midi_channel);
    const bank = channelBank(ch_index);
    const local = channelLocal(ch_index);
    const mod_off = mod_offsets[local];
    const car_off = car_offsets[local];
    const pitch = notePitch(routed_note);
    const pan = panForMidi(midi_channel, ch_index);
    const tl_car = scaledTotalLevel(patch.car_tl, velocity, state.volume, state.expression);
    const tl_mod = scaledTotalLevel(patch.mod_tl, velocity, state.volume, state.expression);

    _ = writeRegister(bank, 0x20 + mod_off, patch.mod_mul);
    _ = writeRegister(bank, 0x20 + car_off, patch.car_mul);
    _ = writeRegister(bank, 0x40 + mod_off, tl_mod);
    _ = writeRegister(bank, 0x40 + car_off, tl_car);
    _ = writeRegister(bank, 0x60 + mod_off, patch.mod_ad);
    _ = writeRegister(bank, 0x60 + car_off, patch.car_ad);
    _ = writeRegister(bank, 0x80 + mod_off, patch.mod_sr);
    _ = writeRegister(bank, 0x80 + car_off, patch.car_sr);
    _ = writeRegister(bank, 0xE0 + mod_off, patch.mod_wave);
    _ = writeRegister(bank, 0xE0 + car_off, patch.car_wave);
    _ = writeRegister(bank, 0xA0 + local, @intCast(pitch.fnum & 0x00FF));
    _ = writeRegister(bank, 0xC0 + local, pan | (patch.feedback << 1) | (patch.alg & 0x01));
    _ = writeRegister(bank, 0xB0 + local, 0x20 | (@as(u8, pitch.block) << 2) | @as(u8, @intCast((pitch.fnum >> 8) & 0x03)));

    channels[ch_index].midi_note = note;
    channels[ch_index].midi_velocity = velocity;
    channels[ch_index].midi_channel = midi_channel & 0x0F;
    midi_note_events += 1;
}

pub fn midiNoteOff(note: u8, midi_channel: u8) void {
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        if (!channels[i].key_on or channels[i].midi_note != note or channels[i].midi_channel != (midi_channel & 0x0F)) continue;
        keyOffChannel(i);
    }
}

pub fn midiProgramChange(midi_channel: u8, program: u8) void {
    midi_channels[midi_channel & 0x0F].program = program & 0x7F;
    midi_program_changes += 1;
}

pub fn midiControlChange(midi_channel: u8, controller: u8, value: u8) void {
    const index = midi_channel & 0x0F;
    switch (controller) {
        7 => midi_channels[index].volume = value & 0x7F,
        10 => midi_channels[index].pan = value & 0x7F,
        11 => midi_channels[index].expression = value & 0x7F,
        121 => midi_channels[index] = .{ .program = midi_channels[index].program },
        else => {},
    }
    midi_control_changes += 1;
}

pub fn allNotesOff() void {
    var i: usize = 0;
    while (i < 12) : (i += 1) keyOffChannel(i);
}

pub fn dumpStatus() void {
    k.puts("OPL3:\r\n");
    k.puts("  model=yes writes=");
    k.putDec(writes);
    k.puts(" last=");
    k.putDec(last_bank);
    k.putc(':');
    k.putHex(last_register, 2);
    k.putc('=');
    k.putHex(last_value, 2);
    k.puts(" opl3=");
    k.puts(if (opl3_enabled) "yes" else "no");
    k.puts(" wave=");
    k.puts(if (waveform_select_enabled) "yes" else "no");
    k.puts(" rhythm=");
    k.puts(if (rhythm_enabled) "yes" else "no");
    k.puts(" rhythm_bits=");
    k.putHex(rhythm_bits, 2);
    k.puts(" fourop=");
    k.putHex(four_op_mask, 2);
    k.puts(" active_ch=");
    k.putDec(activeChannelCount());
    k.puts(" voices=");
    k.putDec(activeVoiceCount());
    k.puts(" note_events=");
    k.putDec(midi_note_events);
    k.puts(" programs=");
    k.putDec(midi_program_changes);
    k.puts(" controls=");
    k.putDec(midi_control_changes);
    k.puts(" steals=");
    k.putDec(voice_steals);
    k.puts(" mixed_ch=");
    k.putDec(last_mixed_channels);
    k.puts(" render_blocks=");
    k.putDec(render_blocks);
    k.puts(" frames=");
    k.putDec(render_frames);
    k.puts(" last_ch=");
    k.putDec(last_render_channel);
    k.puts(" sample=");
    if (last_render_sample < 0) {
        k.putc('-');
        k.putDec(@intCast(-last_render_sample));
    } else {
        k.putDec(@intCast(last_render_sample));
    }
    k.puts(" lr=");
    printSigned(last_left_sample);
    k.putc('/');
    printSigned(last_right_sample);
    k.puts("\r\n");
    dumpActiveChannels();
}

fn initChannelOperators() void {
    var bank: usize = 0;
    while (bank < 2) : (bank += 1) {
        var ch: usize = 0;
        while (ch < 9) : (ch += 1) {
            const index = bank * 9 + ch;
            channels[index].mod_operator = bank * 18 + operatorOffsetIndex(mod_offsets[ch]).?;
            channels[index].car_operator = bank * 18 + operatorOffsetIndex(car_offsets[ch]).?;
        }
    }
}

fn decodeGlobal(bank: u8, reg: u8, value: u8) void {
    if (bank == 1 and reg == 0x05) {
        opl3_enabled = (value & 0x01) != 0;
    } else if (bank == 1 and reg == 0x04) {
        four_op_mask = value & 0x3F;
    } else if (bank == 0 and reg == 0x01) {
        waveform_select_enabled = (value & 0x20) != 0;
    } else if (bank == 0 and reg == 0xBD) {
        rhythm_enabled = (value & 0x20) != 0;
        rhythm_bits = value & 0x1F;
    }
}

fn decodeOperator(bank: u8, reg: u8, value: u8) void {
    const family = reg & 0xE0;
    if (family != 0x20 and family != 0x40 and family != 0x60 and family != 0x80 and family != 0xE0) return;
    const op = operatorIndex(bank, reg) orelse return;
    switch (family) {
        0x20 => {
            operators[op].tremolo = (value & 0x80) != 0;
            operators[op].vibrato = (value & 0x40) != 0;
            operators[op].sustain_sound = (value & 0x20) != 0;
            operators[op].key_scale_rate = (value & 0x10) != 0;
            operators[op].multiple = value & 0x0F;
        },
        0x40 => {
            operators[op].key_scale_level = (value >> 6) & 0x03;
            operators[op].total_level = value & 0x3F;
        },
        0x60 => {
            operators[op].attack = (value >> 4) & 0x0F;
            operators[op].decay = value & 0x0F;
        },
        0x80 => {
            operators[op].sustain_level = (value >> 4) & 0x0F;
            operators[op].release = value & 0x0F;
        },
        0xE0 => {
            operators[op].waveform = value & 0x07;
        },
        else => {},
    }
}

fn decodeChannel(bank: u8, reg: u8, value: u8) void {
    const ch = channelIndex(bank, reg) orelse return;
    if (reg >= 0xA0 and reg <= 0xA8) {
        channels[ch].fnum = (channels[ch].fnum & 0x0300) | value;
    } else if (reg >= 0xB0 and reg <= 0xB8) {
        channels[ch].fnum = (channels[ch].fnum & 0x00FF) | (@as(u16, value & 0x03) << 8);
        channels[ch].block = (value >> 2) & 0x07;
        const old_key = channels[ch].key_on;
        channels[ch].key_on = (value & 0x20) != 0;
        if (channels[ch].key_on and !old_key) resetChannelTone(ch);
        if (!channels[ch].key_on) {
            channels[ch].release_frames = NOTE_RELEASE_FRAMES;
        }
    } else if (reg >= 0xC0 and reg <= 0xC8) {
        channels[ch].feedback = (value >> 1) & 0x07;
        channels[ch].algorithm = value & 0x01;
        channels[ch].pan_left = (value & 0x10) != 0;
        channels[ch].pan_right = (value & 0x20) != 0;
    }
}

fn channelIndex(bank: u8, reg: u8) ?usize {
    if (bank > 1) return null;
    const lo = reg & 0x0F;
    if (lo > 8) return null;
    if ((reg >= 0xA0 and reg <= 0xA8) or (reg >= 0xB0 and reg <= 0xB8) or (reg >= 0xC0 and reg <= 0xC8)) {
        return @as(usize, bank) * 9 + lo;
    }
    return null;
}

fn operatorIndex(bank: u8, reg: u8) ?usize {
    if (bank > 1) return null;
    const offset = reg & 0x1F;
    const local = operatorOffsetIndex(offset) orelse return null;
    return @as(usize, bank) * 18 + local;
}

fn operatorOffsetIndex(offset: u8) ?usize {
    var i: usize = 0;
    while (i < operator_offsets.len) : (i += 1) {
        if (operator_offsets[i] == offset) return i;
    }
    return null;
}

fn activeChannelCount() u32 {
    var count: u32 = 0;
    var i: usize = 0;
    while (i < channels.len) : (i += 1) {
        if (channels[i].key_on) count += 1;
    }
    return count;
}

fn activeVoiceCount() u32 {
    var count: u32 = 0;
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        if (channels[i].key_on and channels[i].midi_note != 0xFF) count += 1;
    }
    return count;
}

fn renderChannelSample(ch: *Channel) i32 {
    const mod = &operators[ch.mod_operator];
    const car = &operators[ch.car_operator];
    var feedback_phase: i32 = 0;
    if (ch.feedback != 0) {
        const fb = @divTrunc(ch.feedback_prev + ch.feedback_last, 2);
        feedback_phase = @divTrunc(fb * @as(i32, ch.feedback), 16);
    }

    const mod_sample = @as(i32, renderOperatorSample(mod, ch, feedback_phase));
    ch.feedback_prev = ch.feedback_last;
    ch.feedback_last = mod_sample;

    var sample: i32 = if (ch.algorithm == 0)
        renderOperatorSample(car, ch, @divTrunc(mod_sample, 2))
    else blk: {
        const car_sample = @as(i32, renderOperatorSample(car, ch, 0));
        break :blk @divTrunc(mod_sample + car_sample, 2);
    };

    if (!ch.key_on) {
        sample = @divTrunc(sample * @as(i32, ch.release_frames), NOTE_RELEASE_FRAMES);
        if (ch.release_frames > 0) ch.release_frames -= 1;
        if (ch.release_frames == 0) {
            ch.midi_note = 0xFF;
            ch.midi_velocity = 0;
            ch.midi_channel = 0xFF;
        }
    }
    return sample;
}

fn mixDivisor(mixed_channels: u8) i32 {
    if (mixed_channels <= 2) return 1;
    if (mixed_channels <= 5) return 2;
    return 3;
}

fn allocateVoice(note: u8, midi_channel: u8) usize {
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        if (channels[i].key_on and channels[i].midi_note == note and channels[i].midi_channel == (midi_channel & 0x0F)) return i;
    }
    i = 0;
    while (i < 12) : (i += 1) {
        if (!channels[i].key_on) return i;
    }
    voice_steals += 1;
    keyOffChannel(0);
    return 0;
}

fn keyOffChannel(ch_index: usize) void {
    const bank = channelBank(ch_index);
    const local = channelLocal(ch_index);
    const ch = &channels[ch_index];
    const value: u8 = (@as(u8, ch.block) << 2) | @as(u8, @intCast((ch.fnum >> 8) & 0x03));
    _ = writeRegister(bank, 0xB0 + local, value);
}

fn resetChannelTone(ch_index: usize) void {
    const ch = &channels[ch_index];
    const mod = &operators[ch.mod_operator];
    const car = &operators[ch.car_operator];
    mod.phase = 0;
    mod.envelope = 0;
    mod.age_frames = 0;
    car.phase = 0;
    car.envelope = 0;
    car.age_frames = 0;
    ch.feedback_prev = 0;
    ch.feedback_last = 0;
    ch.release_frames = 0;
}

const NotePitch = struct {
    fnum: u16,
    block: u3,
};

fn notePitch(note: u8) NotePitch {
    const fnums = [_]u16{ 343, 363, 385, 408, 432, 458, 485, 514, 544, 577, 611, 647 };
    const idx: usize = note % 12;
    var block: u8 = if (note >= 24) (note / 12) - 2 else 0;
    if (block > 7) block = 7;
    return .{ .fnum = fnums[idx], .block = @intCast(block) };
}

fn noteForMidi(midi_channel: u8, note: u8) u8 {
    if ((midi_channel & 0x0F) != 9) return note;
    return switch (note) {
        35, 36 => 45,
        38, 40 => 60,
        41, 43, 45, 47, 48, 50 => 48 + (note & 0x07),
        42, 44, 46 => 82,
        49, 51, 52, 55, 57, 59 => 88,
        else => if (note <= 103) note + 24 else note,
    };
}

fn panForMidi(midi_channel: u8, ch_index: usize) u8 {
    const state = midi_channels[midi_channel & 0x0F];
    if (state.pan < 44) return 0x10;
    if (state.pan > 84) return 0x20;
    if (midi_channel % 3 == 0 or ch_index % 3 == 0) return 0x10;
    if (midi_channel % 3 == 1 or ch_index % 3 == 1) return 0x20;
    return 0x30;
}

fn scaledTotalLevel(base: u8, velocity: u8, volume: u8, expression: u8) u8 {
    var level: u32 = @as(u32, velocity) * @as(u32, volume);
    level = (level * @as(u32, expression)) / (127 * 127);
    const attenuation = (127 - level) * 24 / 127;
    return capU6(@as(u32, base) + attenuation);
}

fn patchForMidi(midi_channel: u8, program: u8, note: u8) Patch {
    if ((midi_channel & 0x0F) == 9) return drumPatch(note);
    if (program >= 32 and program <= 39) return builtinBassPatch();
    return builtinDefaultPatch();
}

fn builtinDefaultPatch() Patch {
    return .{ .mod_mul = 0x01, .car_mul = 0x01, .mod_tl = 63, .car_tl = 6, .mod_ad = 0xA3, .car_ad = 0xF3, .mod_sr = 0x77, .car_sr = 0x67, .mod_wave = 0, .car_wave = 0, .alg = 0, .feedback = 0 };
}

fn builtinBassPatch() Patch {
    return .{ .mod_mul = 0x01, .car_mul = 0x01, .mod_tl = 63, .car_tl = 2, .mod_ad = 0xF3, .car_ad = 0xF3, .mod_sr = 0x54, .car_sr = 0x63, .mod_wave = 0, .car_wave = 4, .alg = 0, .feedback = 0 };
}

fn drumPatch(note: u8) Patch {
    return switch (note) {
        35, 36 => .{ .mod_mul = 0x21, .car_mul = 0x01, .mod_tl = 18, .car_tl = 4, .mod_ad = 0xF7, .car_ad = 0xF7, .mod_sr = 0x81, .car_sr = 0x81, .mod_wave = 0, .car_wave = 0, .alg = 0, .feedback = 2 },
        38, 40 => .{ .mod_mul = 0x32, .car_mul = 0x12, .mod_tl = 16, .car_tl = 7, .mod_ad = 0xF5, .car_ad = 0xF4, .mod_sr = 0x41, .car_sr = 0x41, .mod_wave = 0, .car_wave = 0, .alg = 1, .feedback = 1 },
        42, 44, 46 => .{ .mod_mul = 0x24, .car_mul = 0x22, .mod_tl = 20, .car_tl = 9, .mod_ad = 0xF2, .car_ad = 0xF2, .mod_sr = 0x21, .car_sr = 0x21, .mod_wave = 0, .car_wave = 0, .alg = 1, .feedback = 0 },
        49, 51, 52, 55, 57, 59 => .{ .mod_mul = 0x34, .car_mul = 0x21, .mod_tl = 18, .car_tl = 8, .mod_ad = 0xF3, .car_ad = 0xF3, .mod_sr = 0x31, .car_sr = 0x31, .mod_wave = 0, .car_wave = 0, .alg = 1, .feedback = 1 },
        else => .{ .mod_mul = 0x21, .car_mul = 0x01, .mod_tl = 20, .car_tl = 7, .mod_ad = 0xF4, .car_ad = 0xF3, .mod_sr = 0x42, .car_sr = 0x42, .mod_wave = 0, .car_wave = 0, .alg = 1, .feedback = 1 },
    };
}

fn capU6(value: u32) u8 {
    if (value > 63) return 63;
    return @intCast(value);
}

fn channelBank(ch_index: usize) u8 {
    return if (ch_index >= 9) 1 else 0;
}

fn channelLocal(ch_index: usize) u8 {
    return @intCast(ch_index % 9);
}

fn renderOperatorSample(op: *Operator, ch: *const Channel, phase_mod: i32) i16 {
    const step = phaseStep(op, ch);
    op.phase +%= step;
    op.age_frames += 1;
    op.envelope = envelopeLevel(op);

    var phase = op.phase;
    if (phase_mod != 0) {
        const phase_delta: u32 = @bitCast(@as(i32, phase_mod));
        phase +%= phase_delta;
    }

    var sample = waveformSample(op.waveform, phase);
    const level = 63 - @as(i32, op.total_level);
    sample = @divTrunc(sample * level, 63);
    sample = @divTrunc(sample * @as(i32, op.envelope), 1024);
    if (sample > 20_000) sample = 20_000;
    if (sample < -20_000) sample = -20_000;
    return @intCast(sample);
}

const RhythmMix = struct {
    left: i32,
    right: i32,
    active: bool,
};

fn renderRhythmSample() RhythmMix {
    var left: i32 = 0;
    var right: i32 = 0;
    var active = false;
    const noise = nextNoise();

    if ((rhythm_bits & 0x10) != 0) {
        active = true;
        const kick = renderDrumTone(6, 90, 12_000);
        left += kick;
        right += kick;
    }
    if ((rhythm_bits & 0x08) != 0) {
        active = true;
        operators[7].age_frames += 1;
        const snare = @divTrunc(noise * rhythmEnvelope(7), 1024);
        left += snare;
        right += snare;
    }
    if ((rhythm_bits & 0x04) != 0) {
        active = true;
        const tom = renderDrumTone(8, 180, 8_000);
        left += tom;
    }
    if ((rhythm_bits & 0x02) != 0) {
        active = true;
        operators[9].age_frames += 1;
        const cym = @divTrunc((noise + renderMetallic(11_000)) * rhythmEnvelope(9), 2048);
        right += cym;
    }
    if ((rhythm_bits & 0x01) != 0) {
        active = true;
        operators[10].age_frames += 1;
        const hat = @divTrunc((noise + renderMetallic(7_000)) * rhythmEnvelope(10), 2048);
        left += hat;
        right += @divTrunc(hat, 2);
    }

    return .{ .left = left, .right = right, .active = active };
}

fn renderDrumTone(index: usize, base_hz: u32, volume: i32) i32 {
    const op = &operators[index % operators.len];
    const step = (base_hz * 65_536) / SAMPLE_RATE;
    op.phase +%= step;
    op.age_frames += 1;
    const env = rhythmEnvelope(index);
    const wave = waveformSample(0, op.phase);
    const by_volume = @divTrunc(wave * volume, 32_767);
    return @divTrunc(by_volume * @as(i32, env), 1024);
}

fn renderMetallic(hz: u32) i32 {
    operators[11].phase +%= (hz * 65_536) / SAMPLE_RATE;
    return if ((operators[11].phase & 0x8000) == 0) 9_000 else -9_000;
}

fn rhythmEnvelope(index: usize) u16 {
    const op = &operators[index % operators.len];
    const pos = op.age_frames % 12_000;
    if (pos < 400) return 1024;
    if (pos > 4_800) return 0;
    return @intCast(1024 - ((pos - 400) * 1024 / 4_400));
}

fn nextNoise() i32 {
    const bit = ((noise_state >> 0) ^ (noise_state >> 2) ^ (noise_state >> 3) ^ (noise_state >> 5)) & 1;
    noise_state = (noise_state >> 1) | (bit << 31);
    return if ((noise_state & 1) == 0) 12_000 else -12_000;
}

fn clampI16(value: i32) i16 {
    if (value > 32_000) return 32_000;
    if (value < -32_000) return -32_000;
    return @intCast(value);
}

fn printSigned(value: i16) void {
    if (value < 0) {
        k.putc('-');
        k.putDec(@intCast(-value));
    } else {
        k.putDec(@intCast(value));
    }
}

fn phaseStep(op: *const Operator, ch: *const Channel) u32 {
    const multiple = if (op.multiple == 0) 1 else @as(u32, op.multiple);
    const block_shift: u5 = @intCast(ch.block);
    var hz = (@as(u32, ch.fnum) << block_shift) / 8;
    if (hz == 0) hz = 1;
    hz *= multiple;
    if (hz > 8_000) hz = 8_000;
    return (hz * 65_536) / SAMPLE_RATE;
}

fn envelopeLevel(op: *const Operator) u16 {
    const attack_frames = rateFrames(op.attack, 256, 8192);
    const decay_frames = rateFrames(op.decay, 512, 16_384);
    const sustain = 1024 - (@as(u32, op.sustain_level) * 48);
    if (op.age_frames < attack_frames) {
        return @intCast((op.age_frames * 1024) / attack_frames);
    }
    const decay_age = op.age_frames - attack_frames;
    if (decay_age < decay_frames) {
        const drop = 1024 - sustain;
        return @intCast(1024 - ((decay_age * drop) / decay_frames));
    }
    return @intCast(sustain);
}

fn rateFrames(rate: u8, fastest: u64, slowest: u64) u64 {
    if (rate >= 15) return fastest;
    if (rate == 0) return slowest;
    return fastest + ((@as(u64, 15 - rate) * (slowest - fastest)) / 15);
}

fn waveformSample(waveform: u8, phase: u32) i32 {
    const p: u16 = @intCast(phase & 0xFFFF);
    const sine = sineSample(p);
    return switch (waveform & 0x07) {
        0 => sine,
        1 => if (sine < 0) 0 else sine,
        2 => if (sine < 0) -sine else sine,
        3 => if (p < 0x8000) 18_000 else -18_000,
        4 => triangleSample(p),
        else => sine,
    };
}

fn triangleSample(p: u16) i32 {
    const pos: i32 = @intCast(p);
    if (pos < 16_384) return pos * 2;
    if (pos < 49_152) return 32_767 - ((pos - 16_384) * 2);
    return -32_767 + ((pos - 49_152) * 2);
}

fn sineSample(p: u16) i32 {
    const quadrant = p >> 14;
    const offset: u16 = p & 0x3FFF;
    var index: usize = @intCast(offset >> 9);
    if (index > 32) index = 32;
    return switch (quadrant) {
        0 => sine_quarter[index],
        1 => sine_quarter[32 - index],
        2 => -sine_quarter[index],
        else => -sine_quarter[32 - index],
    };
}

fn dumpActiveChannels() void {
    var printed: u32 = 0;
    var i: usize = 0;
    while (i < channels.len and printed < 4) : (i += 1) {
        if (!channels[i].key_on and channels[i].fnum == 0 and channels[i].feedback == 0) continue;
        const mod = &operators[channels[i].mod_operator];
        const car = &operators[channels[i].car_operator];
        k.puts("  ch");
        k.putDec(i);
        k.puts(": key=");
        k.puts(if (channels[i].key_on) "on" else "off");
        k.puts(" fnum=");
        k.putDec(channels[i].fnum);
        k.puts(" block=");
        k.putDec(channels[i].block);
        k.puts(" alg=");
        k.putDec(channels[i].algorithm);
        k.puts(" fb=");
        k.putDec(channels[i].feedback);
        k.puts(" pan=");
        k.puts(if (channels[i].pan_left) "L" else "-");
        k.puts(if (channels[i].pan_right) "R" else "-");
        k.puts(" mod(mul=");
        k.putDec(mod.multiple);
        k.puts(" tl=");
        k.putDec(mod.total_level);
        k.puts(" ar=");
        k.putDec(mod.attack);
        k.puts(" dr=");
        k.putDec(mod.decay);
        k.puts(") car(mul=");
        k.putDec(car.multiple);
        k.puts(" tl=");
        k.putDec(car.total_level);
        k.puts(" ar=");
        k.putDec(car.attack);
        k.puts(" dr=");
        k.putDec(car.decay);
        k.puts(" wf=");
        k.putDec(car.waveform);
        k.puts(" env=");
        k.putDec(car.envelope);
        k.puts(" rate=");
        k.putDec(SAMPLE_RATE);
        k.puts(")\r\n");
        printed += 1;
    }
    if (printed == 0) k.puts("  channels: none programmed\r\n");
}
