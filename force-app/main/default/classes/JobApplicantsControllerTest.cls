@IsTest
private class JobApplicantsControllerTest {
  @TestSetup
  static void setup() {
    Job__c job = TestDataFactory.createJob('Salesforce Developer');

    // Scores: 90, 40, unscored. Expected order: Alice (90), Bob (40), Cara (no score).
    Candidate__c alice = TestDataFactory.newCandidate('Alice');
    alice.Current_Title__c = 'Developer';
    alice.Years_Experience__c = 6;
    Candidate__c bob = TestDataFactory.newCandidate('Bob');
    Candidate__c cara = TestDataFactory.newCandidate('Cara');
    insert new List<Candidate__c>{ alice, bob, cara };
    TestDataFactory.addCandidateSkills(alice.Id, new List<String>{ 'Apex' });

    Job_Applicant__c bobApplication = TestDataFactory.newApplicant(
      job.Id,
      bob.Id
    );
    bobApplication.Score__c = 40;
    Job_Applicant__c aliceApplication = TestDataFactory.newApplicant(
      job.Id,
      alice.Id
    );
    aliceApplication.Score__c = 90;
    insert new List<Job_Applicant__c>{
      bobApplication,
      TestDataFactory.newApplicant(job.Id, cara.Id),
      aliceApplication
    };
    insert new List<Extraction_Flag__c>{
      TestDataFactory.newFlag(bob.Id, Constants.FLAG_MISSING, 'Phone', null),
      TestDataFactory.newFlag(
        bob.Id,
        Constants.FLAG_MISSING,
        'Education',
        null
      ),
      TestDataFactory.newFlag(
        bob.Id,
        Constants.FLAG_CONFLICT,
        'Years of Experience',
        null
      )
    };
  }

  @IsTest
  static void returnsBestScoreFirstWithDetails() {
    Test.startTest();
    JobApplicantsController.ApplicantPage page = JobApplicantsController.getApplicants(
      getJobId(),
      10,
      0
    );
    Test.stopTest();

    Assert.areEqual(3, page.total);
    Assert.areEqual(3, page.applicants.size());
    Assert.areEqual('Alice', page.applicants[0].name);
    Assert.areEqual('Bob', page.applicants[1].name);
    Assert.areEqual('Cara', page.applicants[2].name);
    Assert.isNull(page.applicants[2].score);

    CandidateCardController.Card alice = page.applicants[0];
    Assert.areEqual('Developer', alice.currentTitle);
    Assert.areEqual(6, alice.yearsExperience);
    Assert.areEqual(new List<String>{ 'Apex' }, alice.skills);
    Assert.areEqual(90, alice.score);
    Assert.isNotNull(alice.applicantId);

    CandidateCardController.Card bob = page.applicants[1];
    Assert.areEqual(2, bob.missingCount);
    Assert.areEqual(0, bob.inferredCount);
    Assert.areEqual(1, bob.conflictCount);
  }

  @IsTest
  static void pagesThroughApplicants() {
    Id jobId = getJobId();

    JobApplicantsController.ApplicantPage first = JobApplicantsController.getApplicants(
      jobId,
      2,
      0
    );
    JobApplicantsController.ApplicantPage second = JobApplicantsController.getApplicants(
      jobId,
      2,
      2
    );

    Assert.areEqual(3, first.total);
    Assert.areEqual(2, first.applicants.size());
    Assert.areEqual(1, second.applicants.size());
    Assert.areEqual('Cara', second.applicants[0].name);
  }

  @IsTest
  static void clampsInvalidPaging() {
    JobApplicantsController.ApplicantPage page = JobApplicantsController.getApplicants(
      getJobId(),
      -5,
      -1
    );

    Assert.areEqual(1, page.applicants.size());
    Assert.areEqual('Alice', page.applicants[0].name);
  }

  @IsTest
  static void jobWithoutApplicantsReturnsEmptyPage() {
    Job__c empty = TestDataFactory.createJob('Empty Job');

    JobApplicantsController.ApplicantPage page = JobApplicantsController.getApplicants(
      empty.Id,
      10,
      0
    );

    Assert.areEqual(0, page.total);
    Assert.isTrue(page.applicants.isEmpty());
  }

  private static Id getJobId() {
    return [SELECT Id FROM Job__c WHERE Name = 'Salesforce Developer'].Id;
  }
}
