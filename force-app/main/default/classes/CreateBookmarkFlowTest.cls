@IsTest
private class CreateBookmarkFlowTest {
    @TestSetup
    static void setup() {
        Candidate__c candidate = new Candidate__c(Name = 'Test Candidate', Email__c = 'candidate@test.cvreview');
        Job__c job = new Job__c(Name = 'Salesforce Developer');
        insert new List<SObject>{ candidate, job };
        insert new Job_Applicant__c(Candidate__c = candidate.Id, Job__c = job.Id, Score__c = 80);
    }

    @IsTest
    static void createsBookmarkWithNotes() {
        Id applicantId = [SELECT Id FROM Job_Applicant__c LIMIT 1].Id;

        Test.startTest();
        Flow.Interview flow = run(applicantId, 'Strong Apex, check LWC in interview');
        Test.stopTest();

        Bookmark__c bookmark = [SELECT Id, Notes__c, Job_Applicant__c, OwnerId, Score__c FROM Bookmark__c];
        Assert.areEqual(bookmark.Id, (Id) flow.getVariableValue('bookmarkId'));
        Assert.isFalse((Boolean) flow.getVariableValue('alreadyBookmarked'));
        Assert.areEqual('Strong Apex, check LWC in interview', bookmark.Notes__c);
        Assert.areEqual(applicantId, bookmark.Job_Applicant__c);
        Assert.areEqual(UserInfo.getUserId(), bookmark.OwnerId);
        Assert.areEqual(80, bookmark.Score__c);
    }

    @IsTest
    static void returnsExistingBookmarkForSameUser() {
        Id applicantId = [SELECT Id FROM Job_Applicant__c LIMIT 1].Id;
        Bookmark__c existing = new Bookmark__c(Job_Applicant__c = applicantId, Notes__c = 'First');
        insert existing;

        Test.startTest();
        Flow.Interview flow = run(applicantId, 'Second');
        Test.stopTest();

        Assert.areEqual(existing.Id, (Id) flow.getVariableValue('bookmarkId'));
        Assert.isTrue((Boolean) flow.getVariableValue('alreadyBookmarked'));
        Assert.areEqual(1, [SELECT COUNT() FROM Bookmark__c]);
        Assert.areEqual('First', [SELECT Notes__c FROM Bookmark__c].Notes__c);
    }

    @IsTest
    static void invalidApplicantFails() {
        Test.startTest();
        try {
            run('not-an-id', 'Notes');
            Assert.fail('Expected the flow to fail');
        } catch (Exception ex) {
            Assert.isNotNull(ex.getMessage());
        }
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Bookmark__c]);
    }

    private static Flow.Interview run(String applicantId, String notes) {
        Flow.Interview flow = Flow.Interview.createInterview(
            'Create_Bookmark',
            new Map<String, Object>{ 'jobApplicantId' => applicantId, 'notes' => notes }
        );
        flow.start();
        return flow;
    }
}
