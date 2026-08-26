# Clean Architecture Rules for Go Backends

## Dependency direction

The standard layers are:

```text
infrastructure -> adapter -> usecase -> domain
```

Outer layers may depend on inner layers. Inner layers must not import outer layers. A repository may
use different directory names; preserve the dependency direction rather than forcing this exact
tree:

```text
backend/
├── domain/
│   ├── entity/
│   └── repository/
├── usecase/
├── adapter/
│   ├── handler/
│   └── repository/
└── infrastructure/
```

## Layer ownership

### Domain

- Own enterprise rules, entities, value objects, and domain errors.
- Keep entities free of framework dependencies, persistence annotations, HTTP status codes, and
  transport models.
- Define repository contracts in an inner layer when they express capabilities the domain or
  application requires. Interfaces describe what is needed, not how storage works.

### Usecase

- Own application-specific workflows and application errors.
- Accept `context.Context` plus an application input type; return a domain entity or usecase result
  type.
- Depend on domain contracts or usecase-owned interfaces for repositories and external services.
- Do not import concrete infrastructure, construct dependencies, access framework request objects,
  return HTTP responses, or know how data is persisted.

Example shape:

```go
type GetUserInput struct {
    UserID string
}

type GetUserResult struct {
    User *entity.User
}

type GetUserUsecase struct {
    users repository.UserRepository
}

func (uc *GetUserUsecase) Execute(
    ctx context.Context,
    input GetUserInput,
) (*GetUserResult, error) {
    user, err := uc.users.GetByID(ctx, input.UserID)
    if err != nil {
        return nil, err
    }
    return &GetUserResult{User: user}, nil
}
```

Place an interface for an external capability at the inner layer that consumes it. Its concrete
implementation belongs in an outer layer.

### Adapter

Handlers:

- Parse and validate transport-level input.
- Convert it into usecase input, invoke the usecase, map inner-layer errors, and build the transport
  response.
- Do not contain business logic, directly access persistence, or depend on a concrete repository
  when a usecase owns the operation.

Repository adapters:

- Implement inner-layer repository contracts.
- Own persistence-specific queries and models.
- Convert persistence records to and from domain entities without leaking persistence models inward.

### Infrastructure

- Own server and framework setup, database connections, middleware, external clients, messaging,
  storage clients, logging implementations, and other drivers.
- Implement interfaces required by inner layers.
- Never make an inner layer import an infrastructure package.

## Composition and data boundaries

Construct concrete implementations only at the application entry point or composition root. The
composition root may know every layer; business logic must not construct dependencies itself.

Use separate representations where their responsibilities differ:

```text
external request -> handler DTO -> usecase input -> domain entity
                                                -> repository -> persistence model
```

Do not reuse transport or persistence models as domain entities merely to reduce mapping code.

## Error ownership

- Domain packages define domain-rule errors.
- Usecase packages define application errors such as `user.ErrUserNotFound`.
- Adapters inspect those inner-layer errors and map them to transport-specific status codes and
  response bodies.
- Inner layers never return framework response types or HTTP status codes.

## Testing

- Unit-test domain behavior, usecase behavior, error cases, and interactions with repository or
  service interfaces using focused fakes, stubs, or mocks.
- Integration-test repository plus persistence, handler plus usecase, and important full flows.
- Do not move business logic outward merely to simplify an integration test.

## Review checklist

- Repository and external-service interfaces are owned by an appropriate inner layer.
- Business logic remains in domain or usecase code.
- Transport conversion and error mapping remain in adapters.
- Infrastructure and persistence models do not leak inward.
- Dependencies point inward and construction occurs only at the composition root.
- Unit and integration tests cover the changed behavior and its failures.
