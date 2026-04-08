using System;

namespace App.Services
{
    public class Service
    {
        // ISSUE: Hardcoded connection string (security vulnerability)
        private string connectionString = "Server=prod;Database=main;User=sa;Password=P@ssw0rd123!";

        public void Connect()
        {
            Console.WriteLine("Connecting to: " + connectionString);
        }
    }
}
