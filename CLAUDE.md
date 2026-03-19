# Project Overview
Customers waiting outside Ooink during busy hours (lunch and dinner) have limited information about the menu. The small restaurant size creates wait times, and potential customers may leave without trying the food if they cannot quickly understand what Ooink offers. 
An AI assistant positioned outside answers basic menu questions, educates customers about specialty items, and creates a memorable brand interaction that generates social media content. 
Do not worry about security as this app just has publicly available restaurant's menu and are building a conversational AI Pig that answers user queries sitting in front of the restaurant in a tablet

# Architecture Principles
MVVM Architecture: Strict separation - ViewModels handle business logic, Views handle UI
No coupling: ViewModels should not depend on each other unless absolutely necessary
Do not use mix of other state management methods like setState(). This project strictly uses only 'Provider' state management

# Workflow
- Be sure to typecheck when you’re done making a series of code changes
- Always refer to the best practices and guidelines provided in the latest documentation of certain packages or libraries

# Rules
- Add minimal comments for functions or methods in nested structures, the comment should be clearly understandable like a friend writing the explanations for another. 
It should define what it does, how it does in very low-level and not too many lines. 
- Never answer anything if you are not 100% confident, ask clarifying questions to get that 100% confidence.
- Always have a birds eye view of how the entire app works before making any changes.
- Never change already existing class/function names. do not delete any existing comments at all.
- Never create redundant testing functions or multiple README files for each setup.
- Always leave the pubspec.yaml dependencies empty to let the dart to select the latest version

# Additional Instructions
1. **Plan first for any non-trivial task**: write a clear step plan, verify it before implementing, and re-plan immediately if something breaks.
2. **Use subagents to manage complexity**: offload research, exploration, or parallel work; keep one focused task per subagent.
3. **Continuously improve your workflow**: record mistakes as rules and review them in future sessions to avoid repeating them.
4. **Verify before declaring completion**: run tests, inspect logs, compare diffs, and ensure behavior actually works.
5. **Prefer simple, clean solutions**: question hacky fixes, avoid over-engineering trivial tasks, and aim for the most direct approach.
6. **Fix bugs proactively**: investigate errors, logs, or failing tests and resolve them without requiring extra direction.
7. **Track execution clearly**: update progress as steps complete and explain changes at a high level.
8. **Focus on root causes with minimal impact**: avoid temporary patches and limit changes strictly to what is necessary.
