
# Context Reinforcement

## Description

When an AI Agent violates prompts system rules or misunderstands context, quickly review relevant documentation, identify the issue, correct the execution method, and re-execute the task correctly.

## Applicable Scenarios

- AI Agent violated guidelines in CLAUDE.md
- AI Agent violated development standards in conduct/
- AI Agent misunderstood business logic (didn't correctly understand `biz/` docs)
- AI Agent misunderstood technical approach (didn't correctly understand `tech/{project}/` docs)
- AI Agent's task execution method doesn't match project requirements
- Need to re-review context and correct task execution method

### Common Error Types

1. **Used non-English code comments**
   - Violation: `conduct/CODE_COMMENTS.md` and CLAUDE.md language requirements
   - Should review: Code comments must be in English

2. **Manually edited dependency files**
   - Violation: `conduct/DEPENDENCIES.md`
   - Should review: Must use package managers (cargo/forge/pnpm) not manual editing of Cargo.toml/package.json

3. **Misunderstood business logic, used outdated design**
   - Misunderstanding: Didn't read the latest `biz/` documentation
   - Should review: Documentation only records current version, ensure using latest design not outdated approach

## Execution Steps

1. **Quick review of prompts system**
   - Read `CLAUDE.md` to confirm highest guidelines
   - Based on current task type, read relevant standard files under `prompts/conduct/`
   - If involving business logic, read docs under `prompts/biz/`
   - If involving project technology, read docs under `prompts/tech/{project}/`

2. **Identify the issue**
   - If violation: Clearly point out which specific rule was violated (cite filename and section)
   - If misunderstanding: Clearly point out what context was misunderstood (business logic/technical approach)
   - Explain what the incorrect execution method was

3. **Determine correct method**
   - Based on standards, explain the correct execution method
   - List specific steps for correct execution

4. **Re-execute the task**
   - Re-execute the original task using the correct method
   - Ensure full compliance with prompts system standards

## Notes

- **Focus on re-execution**: Not for reflection, but to correct and complete the task
- **Must be specific**: Clearly state which rule was violated
- **Immediate correction**: After identifying the issue, immediately re-execute using the correct method
