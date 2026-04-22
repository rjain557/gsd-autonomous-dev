using System.Data;
using Dapper;

namespace Technijian.Api.Repositories;

/// <summary>
/// Repository for project-related data access operations.
/// </summary>
public interface IProjectRepository
{
    /// <summary>
    /// Gets a project by its ID.
    /// </summary>
    Task<ProjectDto?> GetByIdAsync(int id, int tenantId, CancellationToken ct);

    /// <summary>
    /// Gets project custom instructions for a specific chat thread.
    /// </summary>
    Task<string?> GetProjectInstructionsForThreadAsync(Guid threadId, Guid tenantId, CancellationToken ct);
}

/// <summary>
/// Implementation of project repository using Dapper.
/// </summary>
public class ProjectRepository : IProjectRepository
{
    private readonly IDbConnectionFactory _connectionFactory;
    private readonly ILogger<ProjectRepository> _logger;

    /// <summary>
    /// Initializes a new instance of the <see cref="ProjectRepository"/> class.
    /// </summary>
    public ProjectRepository(
        IDbConnectionFactory connectionFactory,
        ILogger<ProjectRepository> logger)
    {
        _connectionFactory = connectionFactory ?? throw new ArgumentNullException(nameof(connectionFactory));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    /// <inheritdoc />
    public async Task<ProjectDto?> GetByIdAsync(int id, int tenantId, CancellationToken ct)
    {
        try
        {
            using var conn = _connectionFactory.CreateConnection();
            var result = await conn.QuerySingleOrDefaultAsync<ProjectDto>(
                "usp_Project_GetById",
                new { Id = id, TenantId = tenantId },
                commandType: CommandType.StoredProcedure);

            return result;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error retrieving project {ProjectId} for tenant {TenantId}", id, tenantId);
            throw;
        }
    }

    /// <inheritdoc />
    public async Task<string?> GetProjectInstructionsForThreadAsync(Guid threadId, Guid tenantId, CancellationToken ct)
    {
        try
        {
            using var conn = _connectionFactory.CreateConnection();
            var result = await conn.QuerySingleOrDefaultAsync<string?>(
                "usp_ChatThread_GetProjectInstructions",
                new { ThreadId = threadId, TenantId = tenantId.ToString() },
                commandType: CommandType.StoredProcedure);

            _logger.LogDebug(
                "Retrieved project instructions for thread {ThreadId}, tenant {TenantId}: {HasInstructions}",
                threadId, tenantId, !string.IsNullOrWhiteSpace(result));

            return result;
        }
        catch (Exception ex)
        {
            _logger.LogError(
                ex,
                "Error retrieving project instructions for thread {ThreadId}, tenant {TenantId}",
                threadId, tenantId);
            throw;
        }
    }
}

/// <summary>
/// Data transfer object for a project.
/// </summary>
public class ProjectDto
{
    /// <summary>
    /// The project ID.
    /// </summary>
    public int Id { get; set; }

    /// <summary>
    /// The tenant ID.
    /// </summary>
    public int TenantId { get; set; }

    /// <summary>
    /// The project name.
    /// </summary>
    public string Name { get; set; } = string.Empty;

    /// <summary>
    /// The project description.
    /// </summary>
    public string? Description { get; set; }

    /// <summary>
    /// Custom instructions for the project.
    /// </summary>
    public string? CustomInstructions { get; set; }

    /// <summary>
    /// The user who created the project.
    /// </summary>
    public string CreatedBy { get; set; } = string.Empty;

    /// <summary>
    /// When the project was created.
    /// </summary>
    public DateTime CreatedAt { get; set; }

    /// <summary>
    /// When the project was last updated.
    /// </summary>
    public DateTime? UpdatedAt { get; set; }

    /// <summary>
    /// Whether the project is deleted.
    /// </summary>
    public bool IsDeleted { get; set; }
}
