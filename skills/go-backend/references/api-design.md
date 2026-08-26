# API Design and Implementation Rules

## Response envelope

Use the repository's established contract when one exists. For a new API with no established
contract, use these shapes consistently:

```json
{
  "data": {},
  "meta": {}
}
```

```json
{
  "error": {
    "code": "invalid_request",
    "message": "Email is required",
    "details": {}
  }
}
```

Do not silently change an already released response envelope. That is an API contract decision and
must be explicit in the requirements.

## HTTP semantics

Use the status that matches the actual outcome:

- `200 OK`: successful request with a response body
- `201 Created`: resource created
- `204 No Content`: successful request with no response body
- `206 Partial Content`: successful range response
- `400 Bad Request`: invalid transport or application input
- `401 Unauthorized`: authentication is required or invalid
- `403 Forbidden`: authenticated caller lacks permission
- `404 Not Found`: resource is not found within the caller's authorized scope
- `409 Conflict`: request conflicts with current resource state
- `416 Range Not Satisfiable`: invalid range
- `500 Internal Server Error`: unexpected server failure

## Error mapping

Application and domain errors are owned by their inner layers. The handler maps them to the API
contract. Do not redefine shadow copies of those errors in the handler.

```go
func (h *Handler) mapError(err error) (int, ErrorResponse) {
    switch {
    case errors.Is(err, user.ErrUserNotFound):
        return http.StatusNotFound, newError("not_found", "Resource not found")
    case errors.Is(err, user.ErrForbidden):
        return http.StatusForbidden, newError("forbidden", "Access denied")
    case errors.Is(err, user.ErrInvalidInput):
        return http.StatusBadRequest, newError("invalid_request", "Invalid request")
    default:
        h.logger.Error("unexpected error", "error", err)
        return http.StatusInternalServerError,
            newError("internal_error", "An unexpected error occurred")
    }
}
```

Do not expose stack traces, SQL errors, internal identifiers, secrets, or unexpected error strings.
Return stable machine-readable codes. Log unexpected failures with enough internal context to
investigate them, subject to the repository's data-handling rules.

## Endpoint checklist

- Authentication is required, or the endpoint is explicitly public.
- Authorization and tenant scope are enforced before returning protected data.
- Transport input is validated and invalid input fails closed.
- Sensitive actions produce the required audit event.
- Error responses do not expose internals.
- Integration tests cover success, invalid input, authorization, not-found behavior, and unexpected
  failures relevant to the endpoint.
