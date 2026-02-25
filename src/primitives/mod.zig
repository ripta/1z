// Re-export types
pub const types = @import("types.zig");
pub const InterpreterError = types.InterpreterError;
pub const Primitive = types.Primitive;

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
pub const mutations = @import("mutations.zig");
pub const streams = @import("streams.zig");
pub const dynamic_vars = @import("dynamic_vars.zig");
pub const type_predicates = @import("type_predicates.zig");
pub const markers = @import("markers.zig");
pub const parse_time_marker = &markers.parse_time_marker;
pub const structs = @import("structs.zig");

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
    mutations.primitives ++
    streams.primitives ++
    dynamic_vars.primitives ++
    type_predicates.primitives ++
    markers.primitives ++
    structs.primitives;
