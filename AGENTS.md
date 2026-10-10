# Documentation

Use ASD-STE100 Simplified Technical English when you write or change documentation.
This rule applies to README files, guides, plans, configuration comments, and release notes.

- Use short sentences. Give each sentence one main subject.
- Use active voice and direct instructions.
- Use one term for each concept. Explain technical terms when necessary.
- Keep commands, code identifiers, configuration keys, and product names exact.
- State tested behavior and support limits. Do not remove a limit to simplify the text.
- Apply this rule to the text you change. Do not rewrite unrelated documents.

# Debug failed lab tests

Use the support bundle from the failed test run before you rerun the test.
Shared fixtures enable automatic bundles when the applier enters `BLOCKED`.

- Find the failed case and its evidence path in the lab `result.json`.
- Check the run logs and the `supportBundle` result. Look for exported files in
  the fixture's `support-bundles/` directory.
- Read `failure.json` first. Check the reason, GTID, SQL and statement outcome.
- Read `bundle.json` for the file inventory. Query the bundled `state.sqlite`
  in read-only mode. Compare the checkpoint, pending intents and saved schemas
  with the failure. Use `relay.frames` when you need the captured events.
- Keep the original evidence. Do not change the bundled database or source files.
- If no bundle exists, check for a collection error. Test setup failures and
  failures outside the applier do not cause a bundle. Use the fixture logs.
- Use the evidence to fix the cause. Rerun the affected cases after the fix.
  If the bundle lacks necessary evidence, add it and test the collection path.

Bundles can contain row data, SQL and logs. Do not put their contents in public
comments. See [the test lab guide](docs/TEST_LAB.md) for the artifact layout.
