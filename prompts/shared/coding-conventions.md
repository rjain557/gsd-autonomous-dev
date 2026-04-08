# Coding Conventions Reference
# Source: Microsoft C# Conventions, React Best Practices, SQL Server Standards

## .NET 8 / C# Conventions

### Naming
| Element | Convention | Example |
|---------|-----------|---------|
| Classes, structs, enums | PascalCase | `UserService`, `OrderStatus` |
| Interfaces | I + PascalCase | `IUserRepository`, `IAuthService` |
| Methods, properties | PascalCase | `GetUserById()`, `IsActive` |
| Parameters, locals | camelCase | `userId`, `orderTotal` |
| Private fields | _camelCase | `_userRepository`, `_logger` |
| DTOs | PascalCase + Dto | `UserResponseDto`, `CreateOrderRequestDto` |

### Architecture
- Repository pattern: `IUserRepository` -> `UserRepository` (Dapper + SPs)
- Service layer: `IUserService` -> `UserService` (business logic)
- Controllers: thin, delegate to services, return `IActionResult`
- DTOs: separate request/response models, never expose entities
- Dependency injection (constructor injection), one class per file
- Allman braces, 4-space indentation, 120-char max line length

### SOLID Principles
- Single Responsibility: One class = one reason to change
- Open/Closed: Extend via interfaces, not modification
- Liskov Substitution: Derived types substitutable for base
- Interface Segregation: Small, focused interfaces
- Dependency Inversion: Depend on abstractions, not concrete types

## React 18 Conventions
- Functional components with hooks ONLY, one per file, named export
- Props interface defined above component, hooks at top of body
- PascalCase components/files, camelCase variables, UPPER_SNAKE_CASE constants
- Error boundaries at route level, loading/skeleton states for async ops

## SQL Server Conventions
- Tables: PascalCase singular (`User`, `OrderItem`)
- SPs: `usp_Entity_Action` (`usp_User_GetById`, `usp_Order_Create`)
- Views: `vw_Description`, Functions: `fn_Description`
- Indexes: `IX_Table_Column`, PKs: `PK_Table`, FKs: `FK_Child_Parent`
- `SET NOCOUNT ON`, `BEGIN TRY/END TRY/BEGIN CATCH/THROW/END CATCH`
- Audit columns on every table, explicit column lists, IF EXISTS for migrations

### Seed Data
- `MERGE` or `IF NOT EXISTS` for idempotency
- FK references must be consistent, realistic timestamps
- Group INSERTs by entity, match Figma mock data exactly
