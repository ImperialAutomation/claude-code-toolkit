---
paths: "**/*test*, **/tests/**, **/conftest.py, **/*.spec.*"
---

# Test Quality Policy

- Tests must verify real behavior through the full stack where possible
- Mocks are ONLY acceptable for external services (third-party APIs, email, payment providers)
- If you mock a database query or internal service, justify WHY in a code comment
- NEVER mock the thing you are testing
- Prefer integration-style tests over heavily mocked unit tests
- Fixtures must reflect realistic data, not minimal placeholders
- Include edge cases in fixture data (empty strings, unicode, boundary values)
- If a fixture represents a user, give it realistic attributes — not `name="test"`, `email="test@test.com"`
- Test five scenarios per feature: happy path, validation errors, auth failures, downstream failures, edge cases
- Write the feature's E2E/integration test as part of that feature, not as a separate later phase
- After a schema change that crosses a language boundary, test the whole chain — regenerate the downstream types and compile/type-check the consumer, not just the source side. "Source tests green" misses the generated-type breakage (e.g. a backend model change that breaks the frontend's generated types)
- A new SDK/third-party call: confirm the method exists on the *installed* version and smoke-test that the call actually succeeds — "no exception raised" is not success, and this holds for manual integration checks too, not only test code
- For every test, ask: "If someone subtly breaks this feature, will THIS test actually fail?"
- For every test, ask: "Am I testing that the code works, or just that it runs without errors?"

## Anti-Patterns

- Write tests that import non-existent classes
- Claim tests pass without showing actual test output
- Mock internal code just to make tests easier to write
- Create fixtures with placeholder data like `name="test"` or `value=123`
- Write tests that only verify "no exception was raised"
