using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using System.ComponentModel.DataAnnotations;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Technijian.Api.Repositories;

namespace Technijian.Api.Controllers;

/// <summary>
/// Controller for managing chat threads and messages with SSE streaming support.
/// </summary>
[ApiController]
[Route("[controller]")]
[Authorize]
public class ChatController : ControllerBase
{
    private readonly IChatRepository _chatRepository;
    private readonly IProjectRepository _projectRepository;
    private readonly ILogger<ChatController> _logger;
    private readonly ITenantContextAccessor _tenantContext;

    /// <summary>
    /// Initializes a new instance of the <see cref="ChatController"/> class.
    /// </summary>
    public ChatController(
        IChatRepository chatRepository,
        IProjectRepository projectRepository,
        ILogger<ChatController> logger,
        ITenantContextAccessor tenantContext)
    {
        _chatRepository = chatRepository ?? throw new ArgumentNullException(nameof(chatRepository));
        _projectRepository = projectRepository ?? throw new ArgumentNullException(nameof(projectRepository));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _tenantContext = tenantContext ?? throw new ArgumentNullException(nameof(tenantContext));
    }

    /// <summary>
    /// Gets all chat threads for the current user.
    /// </summary>
    [HttpGet("threads")]
    public async Task<ActionResult<IEnumerable<ChatThreadDto>>> GetThreads(
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 20,
        CancellationToken cancellationToken = default)
    {
        var tenantId = _tenantContext.TenantId;
        var userId = User.GetUserId();

        _logger.LogInformation(
            "Fetching chat threads for tenant {TenantId}, user {UserId}",
            tenantId, userId);

        var threads = await _chatRepository.GetThreadsAsync(
            tenantId, userId, page, pageSize, cancellationToken);

        return Ok(threads);
    }

    /// <summary>
    /// Creates a new chat thread.
    /// </summary>
    [HttpPost("threads")]
    public async Task<ActionResult<ChatThreadDto>> CreateThread(
        [FromBody] CreateThreadRequest request,
        CancellationToken cancellationToken = default)
    {
        var tenantId = _tenantContext.TenantId;
        var userId = User.GetUserId();

        _logger.LogInformation(
            "Creating chat thread for tenant {TenantId}, user {UserId}, project {ProjectId}",
            tenantId, userId, request.ProjectId);

        var thread = await _chatRepository.CreateThreadAsync(
            tenantId, userId, request.Title, request.ProjectId, cancellationToken);

        return CreatedAtAction(
            nameof(GetThread),
            new { threadId = thread.Id },
            thread);
    }

    /// <summary>
    /// Gets a specific chat thread by ID.
    /// </summary>
    [HttpGet("threads/{threadId:guid}")]
    public async Task<ActionResult<ChatThreadDto>> GetThread(
        Guid threadId,
        CancellationToken cancellationToken = default)
    {
        var tenantId = _tenantContext.TenantId;
        var userId = User.GetUserId();

        var thread = await _chatRepository.GetThreadAsync(
            threadId, tenantId, userId, cancellationToken);

        if (thread == null)
        {
            return NotFound(new { message = "Thread not found" });
        }

        return Ok(thread);
    }

    /// <summary>
    /// Gets messages for a specific chat thread.
    /// </summary>
    [HttpGet("threads/{threadId:guid}/messages")]
    public async Task<ActionResult<IEnumerable<ChatMessageDto>>> GetMessages(
        Guid threadId,
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 50,
        CancellationToken cancellationToken = default)
    {
        var tenantId = _tenantContext.TenantId;
        var userId = User.GetUserId();

        var messages = await _chatRepository.GetMessagesAsync(
            threadId, tenantId, userId, page, pageSize, cancellationToken);

        return Ok(messages);
    }

    /// <summary>
    /// Sends a message and streams the response via SSE.
    /// </summary>
    [HttpPost("threads/{threadId:guid}/messages")]
    public async IAsyncEnumerable<SseEvent> SendMessage(
        Guid threadId,
        [FromBody] SendMessageRequest request,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        var tenantId = _tenantContext.TenantId;
        var userId = User.GetUserId();

        _logger.LogInformation(
            "Sending message in thread {ThreadId} for tenant {TenantId}, user {UserId}",
            threadId, tenantId, userId);

        // Fetch project custom instructions for this thread
        string? projectInstructions = null;
        try
        {
            projectInstructions = await _projectRepository.GetProjectInstructionsForThreadAsync(
                threadId, tenantId, cancellationToken);

            if (!string.IsNullOrWhiteSpace(projectInstructions))
            {
                _logger.LogDebug(
                    "Loaded custom instructions for thread {ThreadId}",
                    threadId);
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(
                ex,
                "Failed to load project custom instructions for thread {ThreadId}",
                threadId);
            // Continue without custom instructions - don't fail the chat
        }

        // Build the system prompt
        var systemPrompt = BuildSystemPrompt(request);

        // Prepend project custom instructions if available
        if (!string.IsNullOrWhiteSpace(projectInstructions))
        {
            systemPrompt = $"[Project Instructions]\n{projectInstructions}\n\n{systemPrompt}";
            _logger.LogDebug("Prepended project instructions to system prompt for thread {ThreadId}", threadId);
        }

        // Persist user message
        await _chatRepository.AddMessageAsync(
            threadId, tenantId, userId, "user", request.Message, cancellationToken);

        // Yield SSE events for the streaming response
        yield return new SseEvent
        {
            Event = "start",
            Data = JsonSerializer.Serialize(new { threadId, messageId = Guid.NewGuid() })
        };

        // Stream the assistant response (placeholder implementation)
        var responseChunks = ProcessChatWithSystemPrompt(systemPrompt, request.Message, cancellationToken);

        await foreach (var chunk in responseChunks.WithCancellation(cancellationToken))
        {
            yield return new SseEvent
            {
                Event = "token",
                Data = JsonSerializer.Serialize(new { content = chunk })
            };
        }

        // Persist assistant response
        var fullResponse = await CollectResponseAsync(responseChunks, cancellationToken);
        await _chatRepository.AddMessageAsync(
            threadId, tenantId, null, "assistant", fullResponse, cancellationToken);

        yield return new SseEvent
        {
            Event = "done",
            Data = JsonSerializer.Serialize(new { threadId })
        };
    }

    /// <summary>
    /// Deletes a chat thread.
    /// </summary>
    [HttpDelete("threads/{threadId:guid}")]
    public async Task<IActionResult> DeleteThread(
        Guid threadId,
        CancellationToken cancellationToken = default)
    {
        var tenantId = _tenantContext.TenantId;
        var userId = User.GetUserId();

        _logger.LogInformation(
            "Deleting thread {ThreadId} for tenant {TenantId}, user {UserId}",
            threadId, tenantId, userId);

        var result = await _chatRepository.DeleteThreadAsync(
            threadId, tenantId, userId, cancellationToken);

        if (!result)
        {
            return NotFound(new { message = "Thread not found" });
        }

        return NoContent();
    }

    /// <summary>
    /// Builds the system prompt based on request parameters.
    /// </summary>
    private static string BuildSystemPrompt(SendMessageRequest request)
    {
        var basePrompt = "You are a helpful AI assistant.";

        if (!string.IsNullOrWhiteSpace(request.SystemPrompt))
        {
            basePrompt = request.SystemPrompt;
        }

        return basePrompt;
    }

    /// <summary>
    /// Processes the chat with the given system prompt (placeholder for LLM integration).
    /// </summary>
    private static async IAsyncEnumerable<string> ProcessChatWithSystemPrompt(
        string systemPrompt,
        string userMessage,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        // Placeholder implementation - would integrate with LLM provider
        var response = "This is a placeholder response. In production, this would stream from an LLM.";
        
        foreach (var word in response.Split(' '))
        {
            if (cancellationToken.IsCancellationRequested)
            {
                yield break;
            }

            await Task.Delay(50, cancellationToken);
            yield return word + " ";
        }
    }

    /// <summary>
    /// Collects the full response from the streaming chunks.
    /// </summary>
    private static async Task<string> CollectResponseAsync(
        IAsyncEnumerable<string> chunks,
        CancellationToken cancellationToken = default)
    {
        var builder = new System.Text.StringBuilder();
        
        await foreach (var chunk in chunks.WithCancellation(cancellationToken))
        {
            builder.Append(chunk);
        }

        return builder.ToString().Trim();
    }
}

#region DTOs

/// <summary>
/// Data transfer object for a chat thread.
/// </summary>
public class ChatThreadDto
{
    public Guid Id { get; set; }
    public Guid TenantId { get; set; }
    public string Title { get; set; } = string.Empty;
    public int? ProjectId { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime? UpdatedAt { get; set; }
}

/// <summary>
/// Data transfer object for a chat message.
/// </summary>
public class ChatMessageDto
{
    public Guid Id { get; set; }
    public Guid ThreadId { get; set; }
    public string Role { get; set; } = string.Empty;
    public string Content { get; set; } = string.Empty;
    public DateTime CreatedAt { get; set; }
}

/// <summary>
/// SSE event structure for streaming responses.
/// </summary>
public class SseEvent
{
    public string Event { get; set; } = string.Empty;
    public string Data { get; set; } = string.Empty;
}

/// <summary>
/// Request to create a new chat thread.
/// </summary>
public class CreateThreadRequest
{
    [Required]
    [StringLength(200, MinimumLength = 1)]
    public string Title { get; set; } = string.Empty;

    public int? ProjectId { get; set; }
}

/// <summary>
/// Request to send a message in a chat thread.
/// </summary>
public class SendMessageRequest
{
    [Required]
    [StringLength(10000, MinimumLength = 1)]
    public string Message { get; set; } = string.Empty;

    public string? SystemPrompt { get; set; }
    public string? Model { get; set; }
}

#endregion

#region Repository Interfaces

/// <summary>
/// Repository interface for chat operations.
/// </summary>
public interface IChatRepository
{
    Task<IEnumerable<ChatThreadDto>> GetThreadsAsync(
        Guid tenantId, string userId, int page, int pageSize, CancellationToken ct);
    
    Task<ChatThreadDto?> GetThreadAsync(
        Guid threadId, Guid tenantId, string userId, CancellationToken ct);
    
    Task<ChatThreadDto> CreateThreadAsync(
        Guid tenantId, string userId, string title, int? projectId, CancellationToken ct);
    
    Task<IEnumerable<ChatMessageDto>> GetMessagesAsync(
        Guid threadId, Guid tenantId, string userId, int page, int pageSize, CancellationToken ct);
    
    Task<ChatMessageDto> AddMessageAsync(
        Guid threadId, Guid tenantId, string? userId, string role, string content, CancellationToken ct);
    
    Task<bool> DeleteThreadAsync(
        Guid threadId, Guid tenantId, string userId, CancellationToken ct);
}

#endregion

#region Tenant Context

/// <summary>
/// Accessor for the current tenant context.
/// </summary>
public interface ITenantContextAccessor
{
    Guid TenantId { get; }
}

#endregion

#region User Extensions

/// <summary>
/// Extension methods for ClaimsPrincipal.
/// </summary>
public static class ClaimsPrincipalExtensions
{
    public static string GetUserId(this System.Security.Claims.ClaimsPrincipal user)
    {
        return user.FindFirst(System.Security.Claims.ClaimTypes.NameIdentifier)?.Value 
            ?? user.FindFirst("oid")?.Value 
            ?? user.FindFirst("sub")?.Value 
            ?? string.Empty;
    }
}

#endregion
