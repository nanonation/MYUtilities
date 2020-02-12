//
//  Test.m
//  MYUtilities
//
//  Created by Jens Alfke on 1/5/08.
//  Copyright 2008-2013 Jens Alfke. All rights reserved.
//

#import "Test.h"

#if DEBUG

#import "ExceptionUtils.h"

BOOL gRunningTestCase;

struct TestCaseLink *gAllTestCases;
static int sPassed, sFailed;
static NSMutableArray* sFailedTestNames;
static struct TestCaseLink *sCurrentTest;
static int sCurTestCaseExceptions;

#if TARGET_OS_IPHONE
#define XML_REPORT 0 // iOS doesn't have NSXML
#else
#define XML_REPORT 1
#endif

#if XML_REPORT
static NSXMLElement* sReportXML;
#endif

static BOOL CheckCoverage(const char* testName);
static BOOL CheckUncalledCoverage(void);


static void TestCaseExceptionReporter( NSException *x ) {
    sCurTestCaseExceptions++;
    fflush(stderr);
    Log(@"XXX FAILED test case -- backtrace:\n%@\n\n", x.my_callStack);
}

static void ReportTestCase(struct TestCaseLink *test, NSString* failureType, NSString* failureMessage) {
#if XML_REPORT
    if (!sReportXML)
        return;
    NSString* name = [NSString stringWithUTF8String: test->name];
    NSXMLElement* testcase = [NSXMLElement elementWithName: @"testcase"];
    [testcase setAttributesWithDictionary: @{@"name": name,
                                             @"classname": name}];
    if ($equal(failureType, @"skipped")) {
        NSXMLElement* skipped = [NSXMLElement elementWithName: @"skipped"];
        if (failureMessage)
            skipped.stringValue = failureMessage;
        [testcase addChild: skipped];
    } else if (failureType != nil) {
        NSXMLElement* failure = [NSXMLElement elementWithName: @"failure"];
        [failure setAttributesWithDictionary: @{@"type": failureType}];
        if (failureMessage)
            [failure setStringValue: failureMessage];
        [testcase addChild: failure];
    }
    [sReportXML addChild: testcase];
#endif
}

static void RecordFailedTest( struct TestCaseLink *test ) {
    if (!sFailedTestNames)
        sFailedTestNames = [[NSMutableArray alloc] init];
    [sFailedTestNames addObject: [NSString stringWithUTF8String: test->name]];
}

static BOOL RunTestCase( struct TestCaseLink *test )
{
    @autoreleasepool {
        if( !test->testptr )
            return YES;     // already ran this test
        
#ifndef MY_DISABLE_LOGGING
        BOOL oldLogging = EnableLog(YES);
#endif
        BOOL wasRunningTestCase = gRunningTestCase;
        gRunningTestCase = YES;
        struct TestCaseLink* prevTest = sCurrentTest;
        sCurrentTest = test;
        
        Log(@"=== Testing %s ...",test->name);
        @try{
            sCurTestCaseExceptions = 0;
            MYSetExceptionReporter(&TestCaseExceptionReporter);
            
            test->testptr();    //SHAZAM!
            
            if (!CheckCoverage(test->name)) {
                Log(@"XXX FAILED test case '%s' due to coverage failures", test->name);
                sFailed++;
                RecordFailedTest(test);
                ReportTestCase(test, @"coverage", nil);
            } else if( sCurTestCaseExceptions > 0 ) {
                Log(@"XXX FAILED test case '%s' due to %i exception(s) already reported above",
                    test->name,sCurTestCaseExceptions);
                sFailed++;
                RecordFailedTest(test);
                ReportTestCase(test, @"exception", $sprintf(@"%d exception(s) already caught",
                                                            sCurTestCaseExceptions));
            } else {
                Log(@"√√√ %s passed\n\n",test->name);
                test->passed = YES;
                sPassed++;
                ReportTestCase(test, nil, nil);
            }
        }@catch( NSException *x ) {
            if( [x.name isEqualToString: @"TestCaseSkipped"] ) {
                Log(@"... skipping test %s since %@\n\n", test->name, x.reason);
                ReportTestCase(test, @"skipped", x.reason);
            } else {
                fflush(stderr);
                Log(@"XXX FAILED test case '%s' due to:\nException: %@\n%@\n\n",
                    test->name,x,x.my_callStack);
                sFailed++;
                RecordFailedTest(test);
                NSString* failureType = x.name;
                NSString* reason = x.reason;
                if ([failureType isEqualToString: NSInternalInconsistencyException])
                    if ([reason hasPrefix: @"Assertion failed: "]) {
                        failureType = @"assertion";
                        reason = [reason substringFromIndex: 18];
                    }
                ReportTestCase(test, failureType, reason);
            }
        }@finally{
            test->testptr = NULL;       // prevents test from being run again
        }
        sCurrentTest = prevTest;
        gRunningTestCase = wasRunningTestCase;
#ifndef MY_DISABLE_LOGGING
        EnableLog(oldLogging);
#endif
        return test->passed;
    }
}


static struct TestCaseLink* FindTestCaseNamed( const char *name ) {
    for( struct TestCaseLink *test = gAllTestCases; test; test=test->next )
        if( strcmp(name,test->name)==0 )
            return test;
    Log(@"... WARNING: Could not find test case named '%s'\n\n",name);
    return NULL;
}


static BOOL RunTestCaseNamed( const char *name )
{
    struct TestCaseLink* test = FindTestCaseNamed(name);
    return test && RunTestCase(test);
}


void _RequireTestCase( const char *name )
{
    struct TestCaseLink* test = FindTestCaseNamed(name);
    if (!test || !test->testptr)
        return;
    if( ! RunTestCase(test) ) {
        [NSException raise: @"TestCaseSkipped" 
                    format: @"prerequisite %s failed", name];
    }
    Log(@"=== Back to test %s ...", sCurrentTest->name);
}


#if XML_REPORT
static void WriteReport(NSString* filename) {
    // See http://stackoverflow.com/a/4925847/98077
    [sReportXML setAttributesWithDictionary: @{@"tests": $sprintf(@"%u", (unsigned)sReportXML.childCount),
                                               @"failures": $sprintf(@"%d", sFailed)}];
    NSXMLDocument* doc = [NSXMLDocument documentWithRootElement: sReportXML];
    doc.documentContentKind = NSXMLDocumentXMLKind;
    doc.characterEncoding = @"UTF-8";
    doc.version = @"1.0";
    doc.standalone = YES;
    NSData* output = [doc XMLDataWithOptions: NSXMLDocumentIncludeContentTypeDeclaration |
                                              NSXMLNodeCompactEmptyElement |
                                              NSXMLNodePrettyPrint];
    [output writeToFile: filename options: NSDataWritingAtomic error: NULL];
}
#endif


void RunTestCases( int argc, const char **argv )
{
    @autoreleasepool {
        sPassed = sFailed = 0;
        sFailedTestNames = nil;
        BOOL stopAfterTests = NO;
#if XML_REPORT
        sReportXML = [NSXMLElement elementWithName: @"testsuite"];
#endif
        BOOL writeReport = NO;
        for( int i=1; i<argc; i++ ) {
            const char *arg = argv[i];
            if( strncmp(arg,"Test_",5)==0 ) {
                arg += 5;
                if( strcmp(arg,"Only")==0 )
                    stopAfterTests = YES;
                else if( strcmp(arg,"Report")==0 )
                    writeReport = YES;
                else if( strcmp(arg,"All") == 0 ) {
                    for( struct TestCaseLink *link = gAllTestCases; link; link=link->next )
                        RunTestCase(link);
                } else {
                    RunTestCaseNamed(arg);
                }
            }
        }
        if (sFailed == 0)
            CheckUncalledCoverage();
        if( sPassed>0 || sFailed>0 || stopAfterTests ) {
            if (writeReport) {
#if XML_REPORT
                WriteReport(@"test_report.xml");
#else
                Warn(@"Write_Report option is not supported on this platform");
#endif
            }
            if( sFailed==0 )
                AlwaysLog(@"√√√√√√ ALL %i TESTS PASSED √√√√√√", sPassed);
            else {
                Warn(@"****** %i of %i TESTS FAILED: %@ ******",
                     sFailed, sPassed+sFailed,
                     [sFailedTestNames componentsJoinedByString: @", "]);
                exit(1);
            }
            if( stopAfterTests ) {
                Log(@"Stopping after tests ('Test_Only' arg detected)");
                exit(0);
            }
        }
        sFailedTestNames = nil;
#if XML_REPORT
        sReportXML = nil;
#endif
    }
}


#pragma mark - TEST COVERAGE:


// Maps test name -> dict([filename, line, teststring] -> int)
static NSMutableDictionary* sCoverageByTest;


// Records the boolean result of a specific Cover() call.
BOOL _Cover(const char *sourceFile, int sourceLine, const char*testName,
            const char *testSource, BOOL whichWay)
{
    if (!gRunningTestCase)
        return whichWay;

    NSString* testKey = @(testName);
    if (!sCoverageByTest)
        sCoverageByTest = [[NSMutableDictionary alloc] init];
    NSMutableDictionary* cases = sCoverageByTest[testKey];
    if (!cases)
        cases = sCoverageByTest[testKey] = [NSMutableDictionary dictionary];

    NSArray* key = @[@(sourceFile), @(sourceLine), @(testSource)];
    int results = [cases[key] intValue];
    if (0 == strcmp(testName, sCurrentTest->name))
        results |= (whichWay ? 2 : 1);      // Bit 0 records a false result, bit 1 records true
    cases[key] = @(results);
    return whichWay;
}

static BOOL CheckCoverage(const char* testName) {
    BOOL ok = YES;
    NSDictionary* cases = sCoverageByTest[@(testName)];
    for (NSArray* key in cases) {
        int results = [cases[key] intValue];
        if (results == 1 || results == 2) {
            Warn(@"Coverage: At %@:%d, only saw (%@) == %s",
                 key[0], [key[1] intValue], key[2], (results==2 ?"YES" : "NO"));
            ok = NO;
        }
    }
    return ok;
}

static BOOL CheckUncalledCoverage(void) {
    if (sCoverageByTest.count == 0)
        return YES;
    Log(@"=== Checking for unreached Cover() calls [UncalledCoverage] ...");

    int failures = 0;
    for (NSString* testName in sCoverageByTest) {
        NSDictionary* cases = sCoverageByTest[testName];
        for (NSArray* key in cases) {
            if ([cases[key] intValue] == 0) {
                Warn(@"Coverage: %@:%d, Cover(%@) unreached by test case %@",
                     key[0], [key[1] intValue], key[2], testName);
                failures++;
            }
        }
    }

    struct TestCaseLink testCase = {NULL, "UncalledCoverage"};
    if (failures == 0) {
        Log(@"√√√ All reached Cover() calls were reached during their test case\n\n");
        sPassed++;
        ReportTestCase(&testCase, nil, nil);
        return YES;
    } else {
        NSString* message = $sprintf(@"%d Cover() calls were reached, but not during their test case", failures);
        Log(@"XXX %@\n\n", message);
        sFailed++;
        RecordFailedTest(&testCase);
        ReportTestCase(&testCase, @"coverage", message);
        return NO;
    }
}


#endif // DEBUG


#pragma mark -
#pragma mark ASSERTION FAILURE HANDLER:


void _AssertFailed(const void *selOrFn, const char *sourceFile, int sourceLine,
                    const char *condString, NSString *message, ... )
{
    if( message ) {
        va_list args;
        va_start(args,message);
        message = [[NSString alloc] initWithFormat: message arguments: args];
        NSLog(@"*** ASSERTION FAILED: %@", message);
        message = [@"Assertion failed: " stringByAppendingString: message];
        va_end(args);
    } else {
        message = [NSString stringWithUTF8String: condString];
        NSLog(@"*** ASSERTION FAILED: %@", message);
    }
    [[NSAssertionHandler currentHandler] handleFailureInFunction: [NSString stringWithUTF8String:selOrFn]
                                                            file: [NSString stringWithUTF8String: sourceFile]
                                                      lineNumber: sourceLine
                                                     description: @"%@", message];
    abort(); // unreachable, but appeases compiler
}


void _AssertAbstractMethodFailed( id rcvr, SEL cmd)
{
    [NSException raise: NSInternalInconsistencyException 
                format: @"Class %@ forgot to implement abstract method %@",
                         [rcvr class], NSStringFromSelector(cmd)];
    abort(); // unreachable, but appeases compiler
}


static NSString* _WhyUnequalObjects(id a, id b, NSString* indent, BOOL *inequal);

static NSString* WhyUnequalArrays(NSArray* a, NSArray* b, NSString* indent, BOOL *inequal) {
    indent = [indent stringByAppendingString: @"\t"];
    NSMutableString* out = [NSMutableString stringWithString: @"Unequal NSArrays:"];
    NSUInteger na = a.count, nb = b.count, n = MAX(na, nb);
    for (NSUInteger i = 0; i < n; i++) {
        id aa = (i < na) ? a[i] : nil;
        id bb = (i < nb) ? b[i] : nil;
        NSString* diff = _WhyUnequalObjects(aa, bb, indent, inequal);
        if (diff)
            [out appendFormat: @"\n%@%u: %@", indent, (unsigned)i, diff];
    }
    return out;
}


static NSString* WhyUnequalDictionaries(NSDictionary* a, NSDictionary* b, NSString* indent, BOOL *inequal) {
    indent = [indent stringByAppendingString: @"\t"];
    NSMutableString* out = [NSMutableString stringWithString: @"Unequal NSDictionaries:"];
    for (id key in a) {
        NSString* diff = _WhyUnequalObjects(a[key], b[key], indent, inequal);
        if (diff)
            [out appendFormat: @"\n%@%@: %@", indent, [key my_compactDescription], diff];
    }
    for (id key in b) {
        if (!a[key]) {
            NSString* diff = _WhyUnequalObjects(a[key], b[key], indent, inequal);
            [out appendFormat: @"\n%@%@: %@", indent, [key my_compactDescription], diff];
        }
    }
    return out;
}


static NSString* _WhyUnequalObjects(id a, id b, NSString* indent, BOOL *inequal) {
    if ($equal(a, b))
        return nil;
    if (indent == nil)
        indent = @"";
    if ([a isKindOfClass: [NSDictionary class]]) {
        if ([b isKindOfClass: [NSDictionary class]]) {
            return WhyUnequalDictionaries(a, b, indent, inequal);
        }
    } else if ([a isKindOfClass: [NSArray class]]) {
        if ([b isKindOfClass: [NSArray class]]) {
            return WhyUnequalArrays(a, b, indent, inequal);
        }
    } else if ([a isKindOfClass: [NSNumber class]]) {
        if ([b isKindOfClass: [NSNumber class]]) {
            double na = [a doubleValue], nb = [b doubleValue];
            if (fabs(na-nb)/fmax(fabs(na),fabs(nb)) < 1.0e-6)
                return nil; // numbers are equal within rounding error
        }
    }

    *inequal = YES;
    return $sprintf(@"%@  ≠  %@", [a my_compactDescription], [b my_compactDescription]);
}


NSString* WhyUnequalObjects(id a, id b) {
    BOOL inequal = NO;
    NSString* why = _WhyUnequalObjects(a, b, nil, &inequal);
    if (!inequal)
        why = nil;
    return why;
}


void _AssertEqual(id val, id expected, const char* valExpr,
                  const char* selOrFn, const char* sourceFile, int sourceLine) {
    if ($equal(val, expected))
        return;
    NSString* diff = WhyUnequalObjects(val, expected);
    if (!diff)
        return; // they're "equal-ish"
    if ([diff rangeOfString: @"\n"].length > 0) {
        // If diff is multi-line, log it but don't put it in the assertion message
        NSLog(@"\n*** Actual vs. expected value of %s :%@\n", valExpr, diff);
        diff = @"(see above)";
    }
    _AssertFailed(selOrFn, sourceFile, sourceLine, valExpr, @"Unexpected value of %s: %@",
                  valExpr, diff);
}


/*
 Copyright (c) 2008-2013, Jens Alfke <jens@mooseyard.com>. All rights reserved.
 
 Redistribution and use in source and binary forms, with or without modification, are permitted
 provided that the following conditions are met:
 
 * Redistributions of source code must retain the above copyright notice, this list of conditions
 and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of conditions
 and the following disclaimer in the documentation and/or other materials provided with the
 distribution.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND 
 FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRI-
 BUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR 
  PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN 
 CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF 
 THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
