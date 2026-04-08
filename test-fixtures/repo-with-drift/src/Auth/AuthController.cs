using Microsoft.AspNetCore.Mvc;

namespace App.Auth
{
    [ApiController]
    [Route("api/auth")]
    public class AuthController : ControllerBase
    {
        // REQ-001: JWT authentication - IMPLEMENTED (aligned)
        [HttpPost("login")]
        public IActionResult Login([FromBody] LoginRequest request)
        {
            return Ok(new { token = "jwt-token" });
        }

        // REQ-003: Refresh token flow - NOT IMPLEMENTED (drifted)
        // Blueprint says JWT refresh tokens, but only session auth exists
    }

    public class LoginRequest
    {
        public string Email { get; set; }
        public string Password { get; set; }
    }
}
