// Re-export types
pub const types = @import("types.zig");
pub const InterpreterError = types.InterpreterError;
pub const Primitive = types.Primitive;
pub const RegistryEntry = types.RegistryEntry;

// Re-export helpers
pub const helpers = @import("helpers.zig");
pub const makeSimpleEffect = helpers.makeSimpleEffect;
pub const makeBoxedEffect = helpers.makeBoxedEffect;
pub const popFixnum = helpers.popFixnum;
pub const popBoolean = helpers.popBoolean;
pub const popQuotation = helpers.popQuotation;
pub const popSymbol = helpers.popSymbol;
pub const popString = helpers.popString;
pub const popStackEffect = helpers.popStackEffect;
pub const popVector = helpers.popVector;
pub const popByteArray = helpers.popByteArray;
pub const popStream = helpers.popStream;
pub const popResource = helpers.popResource;
pub const popMarker = helpers.popMarker;
pub const popStructType = helpers.popStructType;
pub const popStructInstance = helpers.popStructInstance;
pub const popTask = helpers.popTask;
pub const popChannel = helpers.popChannel;

pub const stack = @import("stack.zig");
pub const arithmetic = @import("arithmetic.zig");
pub const control = @import("control.zig");
pub const strings = @import("strings.zig");
pub const misc = @import("misc.zig");
pub const parse_time = @import("parse_time.zig");

pub const errors = @import("errors.zig");
pub const data_structures = @import("data_structures.zig");
pub const functional = @import("functional.zig");
pub const sequences = @import("sequences.zig");
pub const freeze = @import("freeze.zig");
pub const sets = @import("sets.zig");
pub const associative = @import("associative.zig");
pub const streams = @import("streams.zig");
pub const dynamic_vars = @import("dynamic_vars.zig");
pub const type_predicates = @import("type_predicates.zig");
pub const markers = @import("markers.zig");
pub const parse_time_marker = &markers.parse_time_marker;
pub const structs = @import("structs.zig");
pub const env = @import("env.zig");
pub const template = @import("template.zig");
pub const virtual = @import("virtual.zig");
pub const enums = @import("enums.zig");
pub const dispatch_words = @import("dispatch_words.zig");
pub const dispatch_helpers = @import("dispatch_helpers.zig");
pub const time = @import("time.zig");
pub const tasks = @import("tasks.zig");
pub const channels = @import("channels.zig");
pub const iterators = @import("iterators.zig");
pub const protocols = @import("protocols.zig");
pub const sockets = @import("sockets.zig");
pub const introspect = @import("introspect.zig");
pub const builtin_types = @import("builtin_types.zig");
pub const math = @import("math.zig");
pub const bitwise = @import("bitwise.zig");
pub const resources = @import("resources.zig");
pub const ffi_toy = @import("../ffi/toy.zig");
pub const ffi_dynamic = @import("../ffi/dynamic.zig");
pub const ffi_struct = @import("../ffi/ffi_struct.zig");
pub const pragmas = @import("pragmas.zig");
pub const native_dispatch_access = @import("native_dispatch_access.zig");
pub const tls = @import("tls.zig");
pub const sandbox = @import("sandbox.zig");
pub const filesystem = @import("filesystem.zig");
pub const process = @import("process.zig");
pub const hooks = @import("hooks.zig");
pub const signals = @import("signals.zig");
pub const watchers = @import("watchers.zig");
pub const packed_arrays = @import("packed.zig");
pub const simd_vector = @import("simd_vector.zig");
pub const posix = @import("posix.zig");

// Sequence protocol
pub const sequence = @import("sequence.zig");
pub const SequenceIterator = sequence.SequenceIterator;
pub const SequenceBuilder = sequence.SequenceBuilder;
pub const SequenceKind = sequence.SequenceKind;
pub const utf8CodepointCount = sequence.utf8CodepointCount;
pub const utf8NthCodepoint = sequence.utf8NthCodepoint;
pub const utf8SliceByCodepoints = sequence.utf8SliceByCodepoints;
pub const sequenceLength = sequence.sequenceLength;
pub const classifySequence = sequence.classifySequence;
pub const sequenceToValues = sequence.sequenceToValues;

// Error mapping
pub const error_mapping = @import("error_mapping.zig");
pub const mapFileOpenError = error_mapping.mapFileOpenError;
pub const mapFileCreateError = error_mapping.mapFileCreateError;
pub const mapFileWriteError = error_mapping.mapFileWriteError;
pub const mapFileReadError = error_mapping.mapFileReadError;
pub const mapFileSyncError = error_mapping.mapFileSyncError;
pub const mapSeekError = error_mapping.mapSeekError;
pub const mapGetPosError = error_mapping.mapGetPosError;
pub const ensureStreamOpen = error_mapping.ensureStreamOpen;
pub const ensureResourceOpen = error_mapping.ensureResourceOpen;

// Aggregated primitives from extracted modules
pub const extracted_primitives = stack.primitives ++
    arithmetic.primitives ++
    control.primitives ++
    strings.primitives ++
    misc.primitives ++
    parse_time.primitives ++
    errors.primitives ++
    data_structures.primitives ++
    functional.primitives ++
    sequences.primitives ++
    freeze.primitives ++
    sets.primitives ++
    associative.primitives ++
    streams.primitives ++
    dynamic_vars.primitives ++
    type_predicates.primitives ++
    markers.primitives ++
    structs.primitives ++
    env.primitives ++
    template.primitives ++
    builtin_types.primitives ++
    virtual.primitives ++
    enums.primitives ++
    dispatch_words.primitives ++
    time.primitives ++
    tasks.primitives ++
    channels.primitives ++
    iterators.primitives ++
    protocols.primitives ++
    sockets.primitives ++
    bitwise.primitives ++
    resources.primitives ++
    pragmas.primitives ++
    tls.primitives ++
    sandbox.primitives ++
    filesystem.primitives ++
    signals.primitives ++
    watchers.primitives ++
    ffi_struct.primitives;

// Aggregated registry entries for the native virtual module
pub const extracted_registry_entries = structs.registry_entries ++
    virtual.registry_entries ++
    enums.registry_entries ++
    protocols.registry_entries ++
    introspect.registry_entries ++
    markers.registry_entries ++
    builtin_types.registry_entries ++
    type_predicates.registry_entries ++
    arithmetic.registry_entries ++
    math.registry_entries ++
    sequences.registry_entries ++
    streams.registry_entries ++
    sockets.registry_entries ++
    iterators.registry_entries ++
    ffi_toy.registry_entries ++
    ffi_dynamic.registry_entries ++
    ffi_struct.registry_entries ++
    native_dispatch_access.registry_entries ++
    tasks.registry_entries ++
    tls.registry_entries ++
    filesystem.registry_entries ++
    process.registry_entries ++
    hooks.registry_entries ++
    signals.registry_entries ++
    posix.registry_entries ++
    misc.registry_entries ++
    packed_arrays.registry_entries ++
    simd_vector.registry_entries ++
    pragmas.registry_entries ++
    functional.registry_entries;
