const std = @import("std");
const Status = std.http.Status;

/// Maps a Zig error to an HTTP status. Errors not listed here become 500.
///
/// Handlers can return these directly (`return error.NotFound;`) and the app
/// turns them into the matching response.
pub fn statusOf(err: anyerror) Status {
    return switch (err) {
        error.BadRequest => .bad_request,
        error.Unauthorized => .unauthorized,
        error.Forbidden => .forbidden,
        error.NotFound => .not_found,
        error.MethodNotAllowed => .method_not_allowed,
        error.Conflict => .conflict,
        error.PayloadTooLarge => .payload_too_large,
        error.UnsupportedMediaType => .unsupported_media_type,
        error.UnprocessableEntity => .unprocessable_entity,
        error.TooManyRequests => .too_many_requests,
        error.BadGateway => .bad_gateway,
        error.ServiceUnavailable => .service_unavailable,
        else => .internal_server_error,
    };
}

test statusOf {
    try std.testing.expectEqual(Status.not_found, statusOf(error.NotFound));
    try std.testing.expectEqual(Status.internal_server_error, statusOf(error.OutOfMemory));
}
