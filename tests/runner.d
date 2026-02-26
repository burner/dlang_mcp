module tests.runner;

import tests.integration.test_e2e_pipeline;
import std.stdio;

void main()
{
	writeln("D Package Search - Integration Test Suite");
	writeln("==========================================");

	bool allPassed = true;

	try {
		writeln("\n--- E2E Pipeline Tests ---");
		auto e2eTests = new E2EPipelineTests();
		e2eTests.runAll();
	} catch(Exception e) {
		writeln("E2E Pipeline tests failed: ", e.msg);
		allPassed = false;
	}

	writeln("\n==========================================");
	if(allPassed) {
		writeln("All integration tests passed!");
	} else {
		writeln("Some integration tests failed.");
	}
}
