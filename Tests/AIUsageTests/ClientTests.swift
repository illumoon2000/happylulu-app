import XCTest
import Darwin
@testable import AIUsagePlugin

final class ClientTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func executable(_ script: String) throws -> String {
        let path = directory.appendingPathComponent("fake-codex")
        try ("#!/usr/bin/python3\n" + script).write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        return path.path
    }

    func testRPCHandshakeNotificationsAndWeeklyUsage() throws {
        let path = try executable(#"""
        import sys,json
        def emit(value): print(json.dumps(value),flush=True)
        for line in sys.stdin:
            req=json.loads(line)
            method=req['method']
            if method=='initialized': continue
            if method=='initialize': result={}
            elif method=='account/read': result={'account':{'type':'chatgpt','email':'test@example.com','planType':'plus'}}
            elif method=='account/rateLimits/read':
                emit({'method':'account/rateLimits/updated','params':{}})
                result={'rateLimitsByLimitId':{'codex':{'secondary':{'usedPercent':28,'windowDurationMins':10080,'resetsAt':2000000000}}}}
            else: raise RuntimeError('Unexpected RPC')
            emit({'id':req['id'],'result':result})
        """#)
        let snapshot = try CodexClient(timeout: 5).fetchBlocking(customPath: path)
        XCTAssertEqual(snapshot.weekly.remainingPercent, 72)
        XCTAssertEqual(snapshot.accountKey?.count, 64)
        XCTAssertFalse(snapshot.accountKey?.contains("test@example.com") ?? true)
    }

    func testLoggedOutAccountAndAPIKeyAreRejected() throws {
        for account in ["None", "{'type':'apiKey'}"] {
            let path = try executable("""
            import sys,json
            for line in sys.stdin:
                req=json.loads(line)
                if 'id' not in req: continue
                result={} if req['method']=='initialize' else {'account':\(account)}
                print(json.dumps({'id':req['id'],'result':result}),flush=True)
            """)
            XCTAssertThrowsError(try CodexClient(timeout: 5).fetchBlocking(customPath: path))
        }
    }

    func testHungServerTimesOutAndIsTerminated() throws {
        let path = try executable("import time\ntime.sleep(30)\n")
        let start = Date()
        XCTAssertThrowsError(try CodexClient(timeout: 0.3).fetchBlocking(customPath: path)) { error in
            guard case UsageError.timeout = error else { return XCTFail("Expected timeout, got \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testInvalidAndDisconnectedResponsesFail() throws {
        for script in ["print('invalid JSON',flush=True)", "pass"] {
            let path = try executable(script)
            XCTAssertThrowsError(try CodexClient(timeout: 2).fetchBlocking(customPath: path))
        }
    }

    func testClosedServerInputDoesNotTerminateClient() throws {
        let childKey = "HAPPY_LULU_AI_USAGE_CLOSED_STDIN_CHILD"
        if ProcessInfo.processInfo.environment[childKey] == "1" {
            // Exercise the normal app signal disposition in an isolated process.
            // A regression must fail this test, never terminate the main test runner.
            signal(SIGPIPE, SIG_DFL)
            let path = try executable(#"""
            import os,sys,json
            request=json.loads(sys.stdin.readline())
            os.close(0)
            print(json.dumps({'id':request['id'],'result':{}}),flush=True)
            """#)
            XCTAssertThrowsError(try CodexClient(timeout: 2).fetchBlocking(customPath: path))
            return
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest",
            "AIUsageTests.ClientTests/testClosedServerInputDoesNotTerminateClient",
            Bundle(for: ClientTests.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment[childKey] = "1"
        child.environment = environment
        let output = Pipe()
        child.standardOutput = output
        child.standardError = output
        try child.run()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        let log = String(decoding: result, as: UTF8.self)
        XCTAssertEqual(child.terminationReason, .exit, log)
        XCTAssertEqual(child.terminationStatus, 0, log)
        XCTAssertTrue(log.contains("Executed 1 test"), "The isolated regression did not run: \(log)")
    }

    func testCustomPathMustBeExecutableFile() throws {
        XCTAssertThrowsError(try CodexExecutable.resolve(customPath: directory.path))
        XCTAssertThrowsError(try CodexExecutable.resolve(customPath: directory.appendingPathComponent("missing").path))
    }

    func testBrowserLoginMatchesCompletionAndReturnsSafeURL() async throws {
        let path = try executable(#"""
        import sys,json
        for line in sys.stdin:
            req=json.loads(line)
            if 'id' not in req: continue
            if req['method']=='initialize': result={}
            elif req['method']=='account/login/start':
                assert req['params']['type']=='chatgpt'
                result={'loginId':'test-login','authUrl':'https://auth.openai.com/authorize'}
            else: raise RuntimeError('Unexpected RPC')
            print(json.dumps({'id':req['id'],'result':result}),flush=True)
            if req['method']=='account/login/start':
                print(json.dumps({'method':'account/login/completed','params':{'loginId':'other','success':False}}),flush=True)
                print(json.dumps({'method':'account/login/completed','params':{'loginId':'test-login','success':True}}),flush=True)
        """#)
        let opened = expectation(description: "Browser URL received")
        try await CodexLoginAttempt(timeout: 5).login(customPath: path) { url in
            XCTAssertEqual(url.absoluteString, "https://auth.openai.com/authorize")
            opened.fulfill()
        }
        await fulfillment(of: [opened], timeout: 1)
    }

    func testBrowserLoginCanBeCancelledWithoutWaitingForTimeout() async throws {
        let path = try executable(#"""
        import sys,json,time
        for line in sys.stdin:
            req=json.loads(line)
            if 'id' not in req: continue
            result={} if req['method']=='initialize' else {'loginId':'test','authUrl':'https://auth.openai.com/authorize'}
            print(json.dumps({'id':req['id'],'result':result}),flush=True)
            if req['method']=='account/login/start': time.sleep(30)
        """#)
        let attempt = CodexLoginAttempt(timeout: 10)
        let start = Date()
        do {
            try await attempt.login(customPath: path) { _ in attempt.cancel() }
            XCTFail("Cancelled login should throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testAsyncFetchCancellationTerminatesSubprocess() async throws {
        let marker = directory.appendingPathComponent("started")
        let path = try executable("""
        import pathlib,time
        pathlib.Path("\(marker.path)").write_text('ready')
        time.sleep(30)
        """)
        let task = Task { try await CodexClient(timeout: 10).fetch(customPath: path) }
        let end = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < end {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testBrowserLoginTimeoutIsActionable() async throws {
        let path = try executable("import time\ntime.sleep(30)\n")
        do {
            try await CodexLoginAttempt(timeout: 0.3).login(customPath: path) { _ in XCTFail("No URL expected") }
            XCTFail("Expected timeout")
        } catch {
            guard case UsageError.loginTimeout = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }
}
