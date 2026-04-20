const API = @import("API");

pub const REFrameworkError = error{
    NullParam,
    ApiCallFailed,
    OutTooSmall,
    Exception,
    InArgsSizeMismatch,
};

pub fn mapResult(result: API.REFrameworkResult) REFrameworkError!void {
    return switch (result) {
        API.REFRAMEWORK_ERROR_NONE => {},
        API.REFRAMEWORK_ERROR_OUT_TOO_SMALL => error.OutTooSmall,
        API.REFRAMEWORK_ERROR_EXCEPTION => error.Exception,
        API.REFRAMEWORK_ERROR_IN_ARGS_SIZE_MISMATCH => error.InArgsSizeMismatch,
        else => error.ApiCallFailed,
    };
}
