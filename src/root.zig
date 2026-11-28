//! tachyon public module.
//!
//! Re-exports the pinned zslay codec, the frame facade, the incremental UTF-8
//! validator, the WebSocket error model, the backpressure policy, the chunked
//! message reader and writer, the RFC 7692 permessage-deflate payload codec,
//! the bounded pub/sub topic hub, the fragment collector, the role-aware
//! connection layer, the split read and write halves, the native `std.Io`
//! stream adapter, the HTTP client handshake and shared server upgrade
//! primitives, and the server upgrade call order.

pub const zslay = @import("zslay");

pub const frame = @import("frame.zig");
pub const Frame = frame.Frame;
pub const Payload = frame.Payload;
pub const OpCode = frame.OpCode;
pub const CloseCode = frame.CloseCode;
pub const MaskingKey = frame.MaskingKey;
pub const MaxHeadSize = frame.MaxHeadSize;
pub const unmask = frame.unmask;
pub const unmask_at = frame.unmask_at;
pub const header_len = frame.header_len;
pub const opcode_from_u8 = frame.opcode_from_u8;
pub const opcode_to_u8 = frame.opcode_to_u8;
pub const close_code_from_u16 = frame.close_code_from_u16;
pub const close_code_to_u16 = frame.close_code_to_u16;
pub const is_valid_close_code = frame.is_valid_close_code;
pub const is_allowed = frame.is_allowed;
pub const is_control = frame.is_control;
pub const validate_close_payload = frame.validate_close_payload;

pub const utf8 = @import("utf8.zig");
pub const Utf8State = utf8.State;
pub const validate_utf8 = utf8.validate;
pub const is_valid_utf8 = utf8.is_valid;
pub const validate_utf8_reader = utf8.validate_reader;

pub const errors = @import("error.zig");
pub const WebSocketError = errors.WebSocketError;
pub const ZslayQueueError = errors.ZslayQueueError;
pub const from_zslay = errors.from_zslay;
pub const from_zslay_close = errors.from_zslay_close;
pub const from_zslay_queue = errors.from_zslay_queue;
pub const invalid_status_code = errors.invalid_status_code;
pub const from_reader = errors.from_reader;
pub const from_writer = errors.from_writer;
pub const from_stream = errors.from_stream;
pub const to_zslay = errors.to_zslay;
pub const description = errors.description;
pub const to_close_code = errors.to_close_code;
pub const is_protocol_error = errors.is_protocol_error;
pub const is_fatal = errors.is_fatal;
pub const is_utf8_error = errors.is_utf8_error;
pub const is_eof_error = errors.is_eof_error;

pub const fragment = @import("fragment.zig");
pub const Fragments = fragment.Fragments;
pub const FragmentCollector = fragment.FragmentCollector;
pub const Role = fragment.Role;

pub const connection = @import("connection.zig");
pub const WebSocket = connection.WebSocket;
pub const ConnectionOptions = connection.Options;
pub const ConnectionConfig = connection.Config;
pub const ConnectionStorage = connection.Storage;
pub const MaskKeySource = connection.MaskKeySource;
pub const default_max_message_size = connection.default_max_message_size;
pub const default_writev_threshold = connection.default_writev_threshold;

pub const backpressure = @import("backpressure.zig");
pub const BackpressureLimits = backpressure.Limits;
pub const BackpressureFlow = backpressure.Flow;
pub const BackpressureState = backpressure.State;
pub const BackpressurePhase = backpressure.Phase;
pub const BackpressureCharge = backpressure.Charge;
pub const BackpressureAction = backpressure.Action;

pub const stream = @import("stream.zig");
pub const MessageReader = stream.MessageReader;
pub const MessageWriter = stream.MessageWriter;
pub const MessageKind = stream.MessageKind;
pub const MessageChunk = stream.Chunk;
pub const MessageEvent = stream.Event;

pub const deflate = @import("deflate.zig");
pub const Deflater = deflate.Deflater;
pub const Inflater = deflate.Inflater;
pub const DeflateConfig = deflate.Config;
pub const DeflateError = deflate.Error;
pub const DeflaterStorage = deflate.DeflaterStorage;
pub const InflaterStorage = deflate.InflaterStorage;
pub const sync_tail = deflate.sync_tail;
pub const max_compressed_len = deflate.max_compressed_len;

pub const handshake = @import("handshake.zig");
pub const HandshakeError = handshake.Error;
pub const HandshakeClientOptions = handshake.ClientOptions;
pub const HandshakeRequest = handshake.Request;
pub const HandshakeResponse = handshake.Response;
pub const accept_guid = upgrade.accept_guid;
pub const accept_token_len = upgrade.accept_token_len;
pub const AcceptTokenBuffer = upgrade.AcceptTokenBuffer;
pub const has_token = handshake.has_token;
pub const generate_handshake_key = handshake.generate_key;
pub const encode_handshake_key = handshake.encode_key;
pub const valid_client_key = handshake.valid_client_key;
pub const compute_accept_token = upgrade.compute_accept_token;
pub const read_handshake_head = handshake.read_head;
pub const verify_handshake_response = handshake.verify;
pub const read_handshake_response = handshake.read_response;
pub const write_handshake_request = handshake.write_request;
pub const client_handshake = handshake.client;
pub const client_handshake_with_key = handshake.client_with_key;
pub const is_upgrade_request = upgrade.is_upgrade_request;
pub const validate_upgrade_request = handshake.validate_request;
pub const read_upgrade_request = handshake.read_request;
pub const write_upgrade_response = handshake.write_response;

pub const upgrade = @import("upgrade.zig");
pub const Upgrade = upgrade.Upgrade;
pub const UpgradeFut = upgrade.UpgradeFut;
pub const IncomingUpgrade = upgrade.IncomingUpgrade;
pub const upgrade_websocket = upgrade.upgrade;
pub const upgrade_websocket_async = upgrade.upgrade_async;
pub const read_incoming_upgrade = upgrade.incoming;

pub const split = @import("split.zig");
pub const Split = split.Split;
pub const WebSocketRead = split.WebSocketRead;
pub const WebSocketWrite = split.WebSocketWrite;
pub const FragmentCollectorRead = split.FragmentCollectorRead;
pub const SplitStorage = split.Storage;
pub const SplitReadStorage = split.ReadStorage;
pub const SplitWriteStorage = split.WriteStorage;
pub const SplitOptions = split.Options;
pub const SplitConfig = split.Config;
pub const after_handshake_split = split.after_handshake_split;

pub const native_stream = @import("native_stream.zig");
pub const NativeTransport = native_stream.Transport;
pub const NativeTransportStorage = native_stream.TransportStorage;
pub const NativeWebSocket = native_stream.WebSocket;
pub const NativeSplit = native_stream.Split;

pub const pubsub = @import("pubsub.zig");
pub const PubSubHub = pubsub.Hub;
pub const PubSubStorage = pubsub.Storage;
pub const PubSubOptions = pubsub.Options;
pub const PubSubTopicId = pubsub.TopicId;
pub const PubSubSubscribeResult = pubsub.SubscribeResult;
pub const PubSubTopicInfo = pubsub.TopicInfo;
pub const PubSubPublishResult = pubsub.PublishResult;
pub const PubSubError = pubsub.Error;
pub const PubSubInitError = pubsub.InitError;
pub const PubSubSubscribeError = pubsub.SubscribeError;
pub const PubSubPublishError = pubsub.PublishError;
pub const required_name_bytes = pubsub.required_name_bytes;
pub const required_index_capacity = pubsub.required_index_capacity;
