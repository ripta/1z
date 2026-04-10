// Re-export types
pub const types = @import("types.zig");
pub const InterpreterError = types.InterpreterError;
pub const Primitive = types.Primitive;
pub const RegistryEntry = types.RegistryEntry;

// Re-export helpers
pub const helpers = @import("helpers.zig");
pub const makeSimpleEffect = helpers.makeSimpleEffect;
pub const popInteger = helpers.popInteger;
pub const popBoolean = helpers.popBoolean;
pub const popQuotation = helpers.popQuotation;
pub const popSymbol = helpers.popSymbol;
pub const popString = helpers.popString;
pub const popStackEffect = helpers.popStackEffect;
pub const popVector = helpers.popVector;
pub const popByteArray = helpers.popByteArray;
pub const popStream = helpers.popStream;
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
    sets.primitives ++
    associative.primitives ++
    streams.primitives ++
    dynamic_vars.primitives ++
    type_predicates.primitives ++
    markers.primitives ++
    structs.primitives ++
    env.primitives ++
    template.primitives ++
    virtual.primitives ++
    enums.primitives ++
    dispatch_words.primitives ++
    time.primitives ++
    tasks.primitives ++
    channels.primitives ++
    iterators.primitives ++
    protocols.primitives ++
    sockets.primitives ++
    introspect.primitives;

// Aggregated registry entries for the native virtual module
pub const extracted_registry_entries = structs.registry_entries ++
    virtual.registry_entries ++
    enums.registry_entries ++
    protocols.registry_entries ++
    introspect.registry_entries;
