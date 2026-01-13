# Project Documentation Creation Context

## Session Purpose

This document provides context setup for AI agents tasked with creating project README files and functional requirement specifications. Each session is ephemeral with limited capacity, requiring focused context to prevent agent wandering and achieve efficient outcomes.

## Context Establishment Process

### Initial Understanding Phase
- Agent reads existing project files completely
- Agent identifies project structure, patterns, and implementation approach
- Agent reviews reference projects for style consistency requirements
- Agent acknowledges scope without offering solutions

### Refinement Phase
- User shares aspects of project that need refinement or clarification
- Agent asks clarifying questions about ambiguous requirements
- Agent confirms understanding of project intent and constraints
- Agent identifies gaps in understanding before proceeding

### Design Alignment Phase
- Agent reviews style patterns from reference projects
- Agent confirms README structure requirements and subdoc organization
- Agent understands functional specification scope - what functionality, not how to implement
- Agent reaches "no more questions" state before implementation authorization

## README Creation Requirements

### Style Consistency
- Follow exact patterns from reference projects in foundation-terraform-bootstrap, foundation-iam-deploy-roles, and website-infrastructure
- Maintain consistent section structure and content organization
- Use established heading patterns and content flow

### Content Structure
- Project title and brief description
- Repository link
- "What Problem This Project Solves" section with bullet points
- "What This Project Does" section with bullet points
- "What This Project Changes" section with Resources Created/Managed and Functional Changes subsections
- Quick Start section with subdoc references
- Subdoc references for AWS Well-Architected Framework, Technologies Used, troubleshooting, prerequisites, script usage
- Copyright matching LICENSE file

### Quality Standards
- Minimal words answering each question completely
- Subdocs referenced at least once in README
- Technologies Used table with Kiro CLI with Claude listed first
- Consistent with project suite patterns

## Functional Specification Requirements

### Content Approach
- Describe what functionality must be implemented, not how
- No code snippets or implementation details
- Force fully functional description enabling design choice consideration
- Written for consumption by another agent as implementation specification

### Documentation Purpose
- Enable another agent to implement required functionality
- Provide complete functional requirements without constraining implementation approach
- Support design decision reasoning through clear functional boundaries

## Session Efficiency Principles

### Focused Context
- Limit context size to task at hand only
- Provide minimal shared standards plus task-specific instructions
- Reduce agent wandering through clear scope boundaries
- Achieve value within session capacity limits

### Task Separation
- This session defines solution and documents it
- Implementation sessions use documentation to execute
- Refactoring sessions focus on specific changes
- Content update sessions handle maintenance tasks

### Context Reuse
- Standalone documents enable session-specific context loading
- Building upon other documents as secondary approach
- Ephemeral sessions require self-contained instruction sets
- Minimal context reduces cognitive load and improves focus
