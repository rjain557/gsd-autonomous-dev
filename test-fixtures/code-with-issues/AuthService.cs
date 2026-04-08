using System;
using System.Security.Cryptography;

namespace App.Auth
{
    public class AuthService
    {
        // SECURITY ISSUE: Hardcoded JWT secret in source code
        private string jwtSecret = "SuperSecretKey123!@#DoNotCommitThis";

        // LINT ISSUE: Unused variable
        private int unusedCounter = 0;

        // LINT ISSUE: Empty catch block swallows exceptions
        public string GenerateToken(string userId)
        {
            try
            {
                // Token generation logic here
                return Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(userId + ":" + jwtSecret));
            }
            catch (Exception)
            {
                // Swallowed!
                return null;
            }
        }

        // SECURITY ISSUE: SQL injection vulnerability
        public void GetUser(string userInput)
        {
            var query = "SELECT * FROM Users WHERE Name = '" + userInput + "'";
            Console.WriteLine(query);
        }
    }
}
