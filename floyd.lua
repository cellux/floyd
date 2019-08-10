local sched = require('sched')
local net = require('net')
local sdl = require('sdl2')
local audio = require('audio')
local sndfile = require('sndfile')
local fluid = require('fluidsynth')
local util = require('util')
local re = require('re')
local stream = require('stream')
local fs = require('fs')
local env = require('env')
local inspect = require('inspect')
local ffi = require('ffi')

local SAMPLE_RATE = 48000
local SAMPLES_PER_BLOCK = 1024

local SFPATH = {
   "/usr/share/soundfonts"
}

ffi.cdef [[ int isatty(int fd); ]]

local M = {}

local AudioDriver = util.Class()

function AudioDriver:new()
   local self = {}
   self.mixer = audio.Mixer()
   self.audio_device = audio.Device {
      freq = SAMPLE_RATE,
      channels = 2,
      samples = SAMPLES_PER_BLOCK,
      source = self.mixer,
   }
   self.playing = false
   return self
end

function AudioDriver:add_source(source)
   self.mixer:add(source)
end

function AudioDriver:start()
   if not self.playing then
      self.audio_device:start()
      self.playing = true
   end
end

function AudioDriver:stop()
   if self.playing then
      self.audio_device:stop()
      self.playing = false
   end
end

function AudioDriver:delete()
   self:stop()
   if self.audio_device then
      self.audio_device:close()
      self.audio_device = nil
   end
   self.mixer = nil
end

local SoundFont = util.Class()

function SoundFont:new(synth, sfont_id)
   return {
      synth = synth,
      sfont_id = sfont_id,
   }
end

local FluidSynth = util.Class()

function FluidSynth:new()
   local self = {}
   local settings = fluid.Settings()
   settings:setnum("synth.gain", 1)
   settings:setint("synth.midi-channels", 256)
   settings:setnum("synth.sample-rate", SAMPLE_RATE)
   self.settings = settings
   self.synth = fluid.Synth(settings)
   return self
end

function FluidSynth:get_audio_source()
   return fluid.AudioSource(self.synth)
end

function FluidSynth:sfload(...)
   local sfont_id = self.synth:sfload(...)
   return SoundFont(self, sfont_id)
end

function FluidSynth:sfont(chan, sfont)
   self.synth:sfont_select(chan, sfont.sfont_id)
end

function FluidSynth:bank(chan, bank)
   self.synth:bank_select(chan, bank)
end

function FluidSynth:program(chan, program)
   self.synth:program_change(chan, program)
end

function FluidSynth:noteon(chan, key, vel)
   self.synth:noteon(chan, key, vel)
end

function FluidSynth:noteoff(chan, key)
   self.synth:noteoff(chan, key)
end

do
   local function defproxy(name)
      FluidSynth[name] = function(self, ...)
         self.synth[name](self.synth, ...)
      end
   end
   defproxy("cc")
   defproxy("pitch_bend")
   defproxy("pitch_wheel_sens")
   defproxy("channel_pressure")
   defproxy("all_notes_off")
   defproxy("all_sounds_off")
end

function FluidSynth:delete()
   if self.synth then
      self.synth:delete()
      self.synth = nil
   end
   if self.settings then
      self.settings:delete()
      self.settings = nil
   end
end

local Scale = util.Class()

function Scale:new(steps)
   local self = {
      offsets = {},
   }
   local offset = 0
   for i=1,#steps do
      table.insert(self.offsets, offset)
      offset = offset + steps[i]
   end
   return self
end

function Scale:at(degree)
   local index = degree % #self.offsets
   local octave_shift = math.floor(degree / #self.offsets)
   return self.offsets[index+1] + octave_shift * 12
end

local function peek_char(s)
   local rv = s:peek(1)
   return rv
end

local function eat_char(s)
   local ch = s:read_char()
end

local function eat_whitespace_and_comments(s)
   while true do
      s:match("^\\s+")
      if not s:match("^#.*?[\r\n]+") then
         -- not a comment
         break
      end
   end
end

local parse_error
local parse_number, parse_string
local parse_note, parse_cluster, parse_rests
local parse_block_name, parse_block
local parse_command, parse_stream

parse_error = function(s, err)
   ef("parse error: %s\nat: [%s]", err, s:readln())
end

local ratio_regex = re.compile("^(-?\\d+)/(\\d+)")
local number_regex = re.compile("^(-?\\d+)(\\.\\d+)?")

parse_number = function(s)
   eat_whitespace_and_comments(s)
   local m = s:match(ratio_regex)
   if m then
      return tonumber(m[1]) / tonumber(m[2])
   end
   local m = s:match(number_regex)
   if m then
      return tonumber(m[0])
   end
   parse_error(s, "expected number")
end

local string_regex = re.compile('^"([^"]*)"')

parse_string = function(s)
   eat_whitespace_and_comments(s)
   local m = s:match(string_regex)
   if not m then
      parse_error(s, "expected string")
   end
   return tostring(m[1])
end

local command_parsers = {}

local function resolve_soundfont_path(path)
   if fs.exists(path) then
      return path
   end
   for _,dir in ipairs(SFPATH) do
      local fullpath = fs.join(dir, path)
      if fs.exists(fullpath) then
         return fullpath
      end
   end
   ef("cannot find soundfont: %s", path)
end

command_parsers['sfload'] = function(s)
   local slot = parse_number(s)
   local path = resolve_soundfont_path(parse_string(s))
   return function(env)
      env.soundfonts[slot] = env.synth:sfload(path)
   end
end

command_parsers['channel'] = function(s)
   local channel = parse_number(s)
   return function(env)
      env.channel = channel
   end
end

command_parsers['sf'] = function(s)
   local slot = parse_number(s)
   return function(env)
      local sfont = env.soundfonts[slot]
      if not sfont then
         ef("no soundfont loaded into slot #%d", slot)
      end
      env.synth:sfont(env.channel, sfont)
   end
end

command_parsers['bank'] = function(s)
   local bank = parse_number(s)
   return function(env)
      env.synth:bank(env.channel, bank)
   end
end

command_parsers['program'] = function(s)
   local program = parse_number(s)
   return function(env)
      env.synth:program(env.channel, program)
   end
end

local function make_number_adjuster(name, min, max)
   local function clamp(value)
      if min and value < min then value = min end
      if max and value > max then value = max end
      return value
   end
   return function(s)
      local value = parse_number(s)
      local next_char = peek_char(s)
      local rel = next_char == '+' or next_char == '-'
      if rel then
         eat_char(s)
         if next_char == '-' then
            value = -value
         end
         return function(env)
            env[name] = clamp(env[name] + value)
         end
      else
         return function(env)
            env[name] = clamp(value)
         end
      end
   end
end

command_parsers['bpm'] = make_number_adjuster("bpm", 1)
command_parsers['vel'] = make_number_adjuster("vel", 0, 127)
command_parsers['dur'] = make_number_adjuster("dur", 0)
command_parsers['delta'] = make_number_adjuster("delta", 1/256)
command_parsers['shift'] = make_number_adjuster("shift")

command_parsers['v'] = command_parsers['vel']
command_parsers['~'] = command_parsers['dur']
command_parsers['>'] = command_parsers['delta']

command_parsers['wait'] = function(s)
   local seconds = parse_number(s)
   return function(env)
      sched.sleep(seconds)
   end
end

command_parsers['scale'] = function(s)
   eat_whitespace_and_comments(s)
   local m = s:match("^[0-9]+")
   if not m then
      parse_error(s, "expected scale steps")
   end
   local match = m[0]
   local steps = {}
   for i=1,#match do
      table.insert(steps, match:byte(i) - 0x30)
   end
   local scale = Scale(steps)
   return function(env)
      env.scale = scale
   end
end

command_parsers['semitones'] = function(s)
   return function(env)
      env.degrees = false
   end
end

command_parsers['degrees'] = function(s)
   return function(env)
      env.degrees = true
   end
end

local note_regex = re.compile("^(-?\\d+|[cdefgab][0-9])(['`_^]*)")

local note_offsets = {
   c = 0,
   d = 2,
   e = 4,
   f = 5,
   g = 7,
   a = 9,
   b = 11,
}

local function AbsNote(value, add)
   return function(env)
      return value + add, env.vel
   end
end

local function RelNote(value, add)
   return function(env)
      local offset = value
      if env.degrees then
         local scale_index = offset + env.shift
         offset = env.scale:at(scale_index)
      end
      return env.root + offset + add, env.vel
   end
end

parse_note = function(s)
   eat_whitespace_and_comments(s)
   local m = s:match(note_regex)
   if not m then
      parse_error(s, "expected note")
   end
   local modifiers = m[2]
   local add = 0
   for i=1,#modifiers do
      local mod = modifiers:sub(i,i)
      if mod == "'" then
         add = add + 1
      elseif mod == "`" then
         add = add - 1
      elseif mod == "^" then
         add = add + 12
      elseif mod == "_" then
         add = add - 12
      end
   end
   local note_str = m[1]
   local first_char = note_str:sub(1,1)
   local note_offset = note_offsets[first_char]
   if note_offset then
      local c4 = 60
      local octave = tonumber(note_str:sub(2,2))
      note_offset = note_offset + (octave-4) * 12
      return AbsNote(c4 + note_offset, add)
   else
      note_offset = tonumber(note_str)
      return RelNote(note_offset, add)
   end
end

command_parsers['root'] = function(s)
   local root_note = parse_note(s)
   return function(env)
      local key, vel = root_note(env)
      env.root = key
   end
end

local function b2s(beats, bpm)
   local beats_per_second = bpm / 60
   local seconds_per_beat = 1 / beats_per_second
   return beats * seconds_per_beat
end

parse_cluster = function(s)
   local notes = {}
   table.insert(notes, parse_note(s))
   while peek_char(s) == ',' do
      eat_char(s)
      table.insert(notes, parse_note(s))
   end
   return function(env)
      local synth = env.synth
      local channel = env.channel
      local bpm = env.bpm
      local dur = env.dur
      local dur_in_seconds = dur and dur > 0 and b2s(dur, bpm)
      local delta = env.delta
      local delta_in_seconds = b2s(delta, bpm)
      local on = {}
      local off = {}
      for i=1,#notes do
         local key, vel = notes[i](env)
         table.insert(on, function()
            synth:noteon(channel, key, vel)
         end)
         if dur_in_seconds then
            table.insert(off, function()
               synth:noteoff(channel, key)
            end)
         end
      end
      sched(function()
         if not env.audio_driver.playing then
            env.audio_driver:start()
         end
         for _,on_fn in ipairs(on) do
            on_fn()
         end
         if dur_in_seconds then
            sched.sleep(dur_in_seconds)
            for _,off_fn in ipairs(off) do
               off_fn()
            end
         end
      end)
      sched.sleep(delta_in_seconds)
   end
end

parse_rests = function(s)
   local count = 0
   while peek_char(s) == '.' do
      eat_char(s)
      count = count + 1
   end
   return function(env)
      local delta_in_seconds = b2s(env.delta * count, env.bpm)
      sched.sleep(delta_in_seconds)
   end
end

local block_name_regex = re.compile("^\\$([a-zA-Z0-9:_-]+)")

parse_block_name = function(s)
   eat_whitespace_and_comments(s)
   local m = s:match(block_name_regex)
   if not m then
      parse_error(s, "expected block name")
   end
   return tostring(m[1])
end

local block_end_regexes = {
   ['{'] = re.compile("^\\s*\\}"),
   ['('] = re.compile("^\\s*\\)"),
}

local function clone_env(env)
   return setmetatable({
      blocks = setmetatable({}, { __index = env.blocks }),
      threads = {},
   }, { __index = env })
end

parse_block = function(s)
   eat_whitespace_and_comments(s)
   local next_char = peek_char(s)
   if next_char == '{' or next_char == '(' then
      -- block definition
      eat_char(s)
      local commands = {}
      local block_end_regex = block_end_regexes[tostring(next_char)]
      assert(block_end_regex)
      while not s:match(block_end_regex) do
         table.insert(commands, parse_command(s))
         eat_whitespace_and_comments(s)
      end
      if next_char == '{' then
         -- block with own subenv
         return function(env)
            local subenv = clone_env(env)
            for _,cmd in ipairs(commands) do
               cmd(subenv)
            end
            if #subenv.threads > 0 then
               sched.join(subenv.threads)
            end
         end
      elseif next_char == '(' then
         -- block inheriting parent env
         return function(env)
            for _,cmd in ipairs(commands) do
               cmd(env)
            end
         end
      end
   elseif next_char == '$' then
      -- block call
      local block_name = parse_block_name(s)
      return function(env)
         local block = env.blocks[block_name]
         if not block then
            ef("invalid block name: %s", block_name)
         end
         block(env)
      end
   else
      parse_error(s, 'expected block')
   end
end

command_parsers['let'] = function(s)
   local block_name = parse_block_name(s)
   local block = parse_block(s)
   return function(env)
      env.blocks[block_name] = block
   end
end

local function make_initial_env()
   return {
      soundfonts = {},
      blocks = {},
      threads = {},
      channel = 0,
      scale = Scale { 2,2,1,2,2,2,1 }, -- major
      degrees = true,
      shift = 0,
      bpm = 120,
      dur = 1,
      delta = 1,
      root = 60,
      vel = 96,
   }
end

command_parsers['rep'] = function(s)
   local count = parse_number(s)
   local block = parse_block(s)
   return function(env)
      for i=1,count do
         block(env)
      end
   end
end

command_parsers['sched'] = function(s)
   local block = parse_block(s)
   return function(env)
      table.insert(env.threads, sched(function() block(env) end))
   end
end

command_parsers['+'] = command_parsers['sched']

command_parsers['quit'] = function(s)
   return function(env)
      env.running = false
   end
end

local command_regex = re.compile("^(sfload|channel|sf|bank|program|bpm|dur|~|delta|>|wait|root|scale|semitones|degrees|vel|v|shift|let|rep|sched|\\+|quit)(?=(\\W|\\d))")

parse_command = function(s)
   eat_whitespace_and_comments(s)
   local m = s:match(command_regex)
   if m then
      local cmd = m[1]
      local parse = command_parsers[cmd]
      return parse(s)
   end
   local m = s:match(note_regex)
   if m then
      s:unread(m[0])
      return parse_cluster(s)
   end
   local next_char = peek_char(s)
   if next_char == '.' then
      return parse_rests(s)
   end
   if next_char == '{' or next_char == '(' or next_char == '$' then
      return parse_block(s)
   end
   parse_error(s, "syntax error")
end

parse_stream = function(s)
   local commands = {}
   while not s:eof() do
      table.insert(commands, parse_command(s))
   end
   return function(env)
      for _,cmd in ipairs(commands) do
         cmd(env)
      end
   end
end

local function run_program(env, path)
   if not fs.exists(path) then
      ef("file not found: %s", path)
   end
   local program_text = fs.readfile(path)
   local program_block = parse_stream(stream(program_text))
   program_block(env)
   local main_block = env.blocks['main']
   if main_block then
      main_block(env)
   end
end

local function run_repl(env)
   local stdin = stream(fs.fd(0))
   local stdout = stream(fs.fd(1))
   local stdio = stream.duplex(stdin, stdout)

   local stdin_isatty = ffi.C.isatty(0) == 1

   local function tty_print(msg)
      if stdin_isatty then
         stdio:write(msg)
      end
   end

   stdio:write("===[ Floyd v1.0.0 ]===\n")
   env.running = true

   while env.running and not stdio:eof() do
      tty_print("> ")
      local ok, cmd = pcall(parse_command, stdio)
      if ok then
         cmd(env)
      else
         stdio:write(tostring(cmd))
         stdio:write("\n")
      end
   end
   tty_print("\n")
end

function M.main()
   local env = make_initial_env()
   env.audio_driver = AudioDriver()
   sched.on('quit', function()
      env.audio_driver:stop()
      env.audio_driver:delete()
      env.audio_driver = nil
   end)
   env.synth = FluidSynth()
   env.audio_driver:add_source(env.synth:get_audio_source())
   sched.on('quit', function()
      env.synth:delete()
      env.synth = nil
   end)
   if arg[1] then
      run_program(env, arg[1])
   else
      run_repl(env)
   end
end

return M
