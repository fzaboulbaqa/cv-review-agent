@IsTest
private class JobApplicantsControllerTest {
  @TestSetup
  static void setup() {
    Job__c job = new Job__c(Name = 'Salesforce Developer');
    Skill__c apex = new Skill__c(Name = 'Apex');
    insert new List<SObject>{ job, apex };

    // Scores: 90, 40, unscored. Expected order: Alice (90), Bob (40), Cara (no score).
    Candidate__c alice = new Candidate__c(
      Name = 'Alice',
      Email__c = 'alice@test.cvreview',
      Current_Title__c = 'Developer',
      Years_Experience__c = 6
    );
    Candidate__c bob = new Candidate__c(
      Name = 'Bob',
      Email__c = 'bob@test.cvreview'
    );
    Candidate__c cara = new Candidate__c(
      Name = 'Cara',
      Email__c = 'cara@test.cvreview'
    );
    insert new List<Candidate__c>{ alice, bob, cara };

    insert new List<SObject>{
      new Job_Applicant__c(
        Candidate__c = bob.Id,
        Job__c = job.Id,
        Score__c = 40
      ),
      new Job_Applicant__c(Candidate__c = cara.Id, Job__c = job.Id),
      new Job_Applicant__c(
        Candidate__c = alice.Id,
        Job__c = job.Id,
        Score__c = 90
      ),
      new Candidate_Skill__c(Candidate__c = alice.Id, Skill__c = apex.Id),
      new Extraction_Flag__c(
        Candidate__c = bob.Id,
        Type__c = 'Missing',
        Field__c = 'Phone__c'
      ),
      new Extraction_Flag__c(
        Candidate__c = bob.Id,
        Type__c = 'Missing',
        Field__c = 'Education__c'
      ),
      new Extraction_Flag__c(
        Candidate__c = bob.Id,
        Type__c = 'Conflict',
        Field__c = 'Years_Experience__c'
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
    Job__c empty = new Job__c(Name = 'Empty Job');
    insert empty;

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
