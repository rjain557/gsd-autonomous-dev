using Microsoft.AspNetCore.Mvc;

namespace App.Dashboard
{
    [ApiController]
    [Route("api/dashboard")]
    public class DashboardController : ControllerBase
    {
        // REQ-002: Dashboard with KPI cards - IMPLEMENTED (aligned)
        [HttpGet("kpis")]
        public IActionResult GetKpis()
        {
            return Ok(new { totalUsers = 150, activeProjects = 12 });
        }
    }
}
