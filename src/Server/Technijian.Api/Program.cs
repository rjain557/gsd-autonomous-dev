using System.Threading.RateLimiting;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Identity.Web;

namespace Technijian.Api;

/// <summary>
/// Application entry point and configuration.
/// </summary>
public class Program
{
    /// <summary>
    /// Main entry point.
    /// </summary>
    public static void Main(string[] args)
    {
        var builder = WebApplication.CreateBuilder(args);

        // Configure services
        ConfigureServices(builder);

        var app = builder.Build();

        // Configure middleware pipeline
        ConfigureMiddleware(app);

        app.Run();
    }

    /// <summary>
    /// Configures application services.
    /// </summary>
    private static void ConfigureServices(WebApplicationBuilder builder)
    {
        var services = builder.Services;
        var configuration = builder.Configuration;

        // Add controllers
        services.AddControllers();

        // Add API versioning
        services.AddApiVersioning(options =>
        {
            options.DefaultApiVersion = new Microsoft.AspNetCore.Mvc.ApiVersion(1, 0);
            options.AssumeDefaultVersionWhenUnspecified = true;
            options.ReportApiVersions = true;
        });

        // Add Azure AD authentication
        services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
            .AddMicrosoftIdentityWebApi(configuration.GetSection("AzureAd"));

        services.AddAuthorization();

        // Add rate limiting with per-user and per-tenant policies
        services.AddRateLimiter(options =>
        {
            options.OnRejected = async (context, cancellationToken) =>
            {
                context.HttpContext.Response.StatusCode = StatusCodes.Status429TooManyRequests;
                context.HttpContext.Response.Headers.Append("Retry-After", "60");
                await context.HttpContext.Response.WriteAsync(
                    "Rate limit exceeded. Please try again later.", cancellationToken);
            };

            // ============================================
            // Per-user rate limit policy
            // Limit: 100 requests per minute per user
            // ============================================
            options.AddFixedWindowLimiter("user", opt =>
            {
                opt.PermitLimit = 100;
                opt.Window = TimeSpan.FromMinutes(1);
                opt.QueueProcessingOrder = QueueProcessingOrder.OldestFirst;
                opt.QueueLimit = 0;
            });

            // ============================================
            // Per-tenant rate limit policy
            // Limit: 1000 requests per minute per tenant
            // ============================================
            options.AddFixedWindowLimiter("tenant", opt =>
            {
                opt.PermitLimit = 1000;
                opt.Window = TimeSpan.FromMinutes(1);
                opt.QueueProcessingOrder = QueueProcessingOrder.OldestFirst;
                opt.QueueLimit = 0;
            });
        });

        // Add CORS
        services.AddCors(options =>
        {
            options.AddPolicy("AllowFrontend", policy =>
            {
                var allowedOrigins = configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() 
                    ?? new[] { "http://localhost:3000", "https://localhost:3000" };
                
                policy.WithOrigins(allowedOrigins)
                    .AllowAnyHeader()
                    .AllowAnyMethod()
                    .AllowCredentials();
            });
        });

        // Add health checks
        services.AddHealthChecks();

        // Add logging
        services.AddLogging(logging =>
        {
            logging.AddConsole();
            logging.AddDebug();
        });

        // Register repositories
        RegisterRepositories(services, configuration);

        // Register tenant context accessor
        services.AddScoped<ITenantContextAccessor, TenantContextAccessor>();
    }

    /// <summary>
    /// Registers repository services.
    /// </summary>
    private static void RegisterRepositories(IServiceCollection services, IConfiguration configuration)
    {
        // Register database connection factory
        services.AddSingleton<IDbConnectionFactory>(provider =>
            new SqlConnectionFactory(configuration.GetConnectionString("DefaultConnection") 
                ?? throw new InvalidOperationException("DefaultConnection string is not configured.")));

        // Register repositories
        services.AddScoped<IChatRepository, ChatRepository>();
        services.AddScoped<IProjectRepository, ProjectRepository>();
    }

    /// <summary>
    /// Configures the HTTP request pipeline.
    /// </summary>
    private static void ConfigureMiddleware(WebApplication app)
    {
        // Exception handling
        if (!app.Environment.IsDevelopment())
        {
            app.UseExceptionHandler("/error");
            app.UseHsts();
        }

        // Enable rate limiting
        app.UseRateLimiter();

        // Enable HTTPS redirection
        app.UseHttpsRedirection();

        // Enable CORS
        app.UseCors("AllowFrontend");

        // Enable authentication and authorization
        app.UseAuthentication();
        app.UseAuthorization();

        // Map controllers
        app.MapControllers();

        // Map health check endpoint
        app.MapHealthChecks("/health");
    }
}

#region Infrastructure Services

/// <summary>
/// Database connection factory interface.
/// </summary>
public interface IDbConnectionFactory
{
    /// <summary>
    /// Creates a new database connection.
    /// </summary>
    System.Data.IDbConnection CreateConnection();
}

/// <summary>
/// SQL Server connection factory implementation.
/// </summary>
public class SqlConnectionFactory : IDbConnectionFactory
{
    private readonly string _connectionString;

    /// <summary>
    /// Initializes a new instance of the <see cref="SqlConnectionFactory"/> class.
    /// </summary>
    public SqlConnectionFactory(string connectionString)
    {
        _connectionString = connectionString ?? throw new ArgumentNullException(nameof(connectionString));
    }

    /// <summary>
    /// Creates a new SQL connection.
    /// </summary>
    public System.Data.IDbConnection CreateConnection()
    {
        return new Microsoft.Data.SqlClient.SqlConnection(_connectionString);
    }
}

/// <summary>
/// Tenant context accessor implementation.
/// </summary>
public class TenantContextAccessor : ITenantContextAccessor
{
    private readonly IHttpContextAccessor _httpContextAccessor;
    private readonly ILogger<TenantContextAccessor> _logger;

    /// <summary>
    /// Initializes a new instance of the <see cref="TenantContextAccessor"/> class.
    /// </summary>
    public TenantContextAccessor(IHttpContextAccessor httpContextAccessor, ILogger<TenantContextAccessor> logger)
    {
        _httpContextAccessor = httpContextAccessor ?? throw new ArgumentNullException(nameof(httpContextAccessor));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    /// <summary>
    /// Gets the current tenant ID from the HTTP context.
    /// </summary>
    public int TenantId
    {
        get
        {
            var httpContext = _httpContextAccessor.HttpContext;
            if (httpContext == null)
            {
                _logger.LogWarning("No HTTP context available for tenant resolution");
                return 0;
            }

            // Try to get tenant from claim
            var tenantClaim = httpContext.User.FindFirst("tenant_id")?.Value
                ?? httpContext.User.FindFirst("tid")?.Value
                ?? httpContext.Request.Headers["X-Tenant-Id"].FirstOrDefault();

            if (!string.IsNullOrEmpty(tenantClaim) && int.TryParse(tenantClaim, out var tenantId))
            {
                return tenantId;
            }

            // Default tenant for development
            if (httpContext.RequestServices.GetRequiredService<IHostEnvironment>().IsDevelopment())
            {
                return 1;
            }

            _logger.LogWarning("Could not resolve tenant ID from request");
            return 0;
        }
    }
}

#endregion

#region Repository Implementations

using Dapper;
using System.Data;

/// <summary>
/// Chat repository implementation using Dapper.
/// </summary>
public class ChatRepository : IChatRepository
{
    private readonly IDbConnectionFactory _connectionFactory;
    private readonly ILogger<ChatRepository> _logger;

    /// <summary>
    /// Initializes a new instance of the <see cref="ChatRepository"/> class.
    /// </summary>
    public ChatRepository(IDbConnectionFactory connectionFactory, ILogger<ChatRepository> logger)
    {
        _connectionFactory = connectionFactory ?? throw new ArgumentNullException(nameof(connectionFactory));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    /// <inheritdoc />
    public async Task<IEnumerable<ChatThreadDto>> GetThreadsAsync(
        int tenantId, string userId, int page, int pageSize, CancellationToken ct)
    {
        using var connection = _connectionFactory.CreateConnection();
        var parameters = new { TenantId = tenantId, UserId = userId, Page = page, PageSize = pageSize };
        
        return await connection.QueryAsync<ChatThreadDto>(
            "usp_ChatThread_GetByUser",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    /// <inheritdoc />
    public async Task<ChatThreadDto?> GetThreadAsync(
        int threadId, int tenantId, string userId, CancellationToken ct)
    {
        using var connection = _connectionFactory.CreateConnection();
        var parameters = new { ThreadId = threadId, TenantId = tenantId, UserId = userId };
        
        return await connection.QuerySingleOrDefaultAsync<ChatThreadDto>(
            "usp_ChatThread_GetById",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    /// <inheritdoc />
    public async Task<ChatThreadDto> CreateThreadAsync(
        int tenantId, string userId, string title, int? projectId, CancellationToken ct)
    {
        using var connection = _connectionFactory.CreateConnection();
        var parameters = new 
        { 
            TenantId = tenantId, 
            UserId = userId, 
            Title = title, 
            ProjectId = projectId 
        };
        
        return await connection.QuerySingleAsync<ChatThreadDto>(
            "usp_ChatThread_Create",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    /// <inheritdoc />
    public async Task<IEnumerable<ChatMessageDto>> GetMessagesAsync(
        int threadId, int tenantId, string userId, int page, int pageSize, CancellationToken ct)
    {
        using var connection = _connectionFactory.CreateConnection();
        var parameters = new 
        { 
            ThreadId = threadId, 
            TenantId = tenantId, 
            UserId = userId,
            Page = page,
            PageSize = pageSize
        };
        
        return await connection.QueryAsync<ChatMessageDto>(
            "usp_ChatMessage_GetByThread",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    /// <inheritdoc />
    public async Task<ChatMessageDto> AddMessageAsync(
        int threadId, int tenantId, string? userId, string role, string content, CancellationToken ct)
    {
        using var connection = _connectionFactory.CreateConnection();
        var parameters = new 
        { 
            ThreadId = threadId, 
            TenantId = tenantId, 
            UserId = userId,
            Role = role,
            Content = content
        };
        
        return await connection.QuerySingleAsync<ChatMessageDto>(
            "usp_ChatMessage_Create",
            parameters,
            commandType: CommandType.StoredProcedure);
    }

    /// <inheritdoc />
    public async Task<bool> DeleteThreadAsync(
        int threadId, int tenantId, string userId, CancellationToken ct)
    {
        using var connection = _connectionFactory.CreateConnection();
        var parameters = new { ThreadId = threadId, TenantId = tenantId, UserId = userId };
        
        var result = await connection.ExecuteAsync(
            "usp_ChatThread_Delete",
            parameters,
            commandType: CommandType.StoredProcedure);
        
        return result > 0;
    }
}

/// <summary>
/// Project repository implementation using Dapper.
/// </summary>
public class ProjectRepository : IProjectRepository
{
    private readonly IDbConnectionFactory _connectionFactory;
    private readonly ILogger<ProjectRepository> _logger;

    /// <summary>
    /// Initializes a new instance of the <see cref="ProjectRepository"/> class.
    /// </summary>
    public ProjectRepository(IDbConnectionFactory connectionFactory, ILogger<ProjectRepository> logger)
    {
        _connectionFactory = connectionFactory ?? throw new ArgumentNullException(nameof(connectionFactory));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    /// <inheritdoc />
    public async Task<ProjectDto?> GetByIdAsync(int id, int tenantId, CancellationToken ct)
    {
        using var connection = _connectionFactory.CreateConnection();
        var parameters = new { Id = id, TenantId = tenantId };
        
        return await connection.QuerySingleOrDefaultAsync<ProjectDto>(
            "usp_Project_GetById",
            parameters,
            commandType: CommandType.StoredProcedure);
    }
}

#endregion
