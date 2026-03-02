\# GSD Engine - Goal-Spec-Done Autonomous Development System



\*\*Version:\*\* 1.1.0 | \*\*Platform:\*\* Windows + PowerShell 5.1+ | \*\*Agents:\*\* Claude Code + Codex CLI



The GSD Engine is a PowerShell-based autonomous development framework that uses AI agents to drive codebases from specification to 100% implementation through iterative convergence loops.



\## What It Does



1\. \*\*Assesses\*\* your codebase against specs (what exists, what is missing, what is broken)

2\. \*\*Converges\*\* existing code toward spec compliance (fix issues, apply patterns)

3\. \*\*Builds\*\* missing features from blueprint manifests (new screens, SPs, components)



\## Quick Start



powershell -ExecutionPolicy Bypass -File install-gsd-all.ps1

\# Restart terminal, then:

cd C:\\path\\to\\your\\repo    # Must be git root with .sln

gsd-assess

gsd-converge

gsd-blueprint



\## Important: Run From Git Root



Always cd into the directory containing .git, .sln, and source code. If nested project folders exist, run from the inner one.



\## Agents

\- \*\*Claude Code\*\* - Reviews, plans, verifies, blueprints

\- \*\*Codex CLI\*\* - Researches, executes code changes, builds



\## Key Features

\- Multi-interface detection (web, MCP, browser, mobile, agent)

\- Auto-discovery of \_analysis/ and \_stubs/ at any depth

\- Live file map updated every iteration

\- Adaptive batch sizing, crash recovery, quota management

\- Spec consistency pre-check

\- Git auto-commit with health scores

\- Idempotent installer (install or update with same command)

