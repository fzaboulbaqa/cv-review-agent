@IsTest
private class ScoringServiceTest {
  // Job "Salesforce Developer": 5 years min, must have Apex + LWC, nice to have Java + Docker.
  @TestSetup
  static void setup() {
    TestDataFactory.createJob(
      'Salesforce Developer',
      5,
      new List<String>{ 'Apex', 'LWC' },
      new List<String>{ 'Java', 'Docker' }
    );
  }

  @IsTest
  static void fullMatchScores100() {
    Job_Applicant__c applicant = apply(
      getJob('Salesforce Developer'),
      8,
      new List<String>{ 'Apex', 'LWC', 'Java', 'Docker' }
    );

    Test.startTest();
    List<ScoringService.Breakdown> breakdowns = ScoringService.scoreApplicants(
      new Set<Id>{ applicant.Job__c }
    );
    Test.stopTest();

    Assert.areEqual(1, breakdowns.size());
    Assert.areEqual(100, breakdowns[0].score);
    Assert.areEqual(0, breakdowns[0].missingMustHave.size());
    Assert.areEqual(100, getScore(applicant.Id));
  }

  @IsTest
  static void partialMatchWithUnknownYears() {
    // 1/2 must (30) + 1/2 nice (10) + unknown years (0) = 40
    Job_Applicant__c applicant = apply(
      getJob('Salesforce Developer'),
      null,
      new List<String>{ 'Apex', 'Java' }
    );

    Test.startTest();
    ScoringService.Breakdown breakdown = ScoringService.scoreApplicants(
      new Set<Id>{ applicant.Job__c }
    )[0];
    Test.stopTest();

    Assert.areEqual(40, breakdown.score);
    Assert.areEqual(new List<String>{ 'LWC' }, breakdown.missingMustHave);
    Assert.areEqual(new List<String>{ 'Docker' }, breakdown.missingNiceToHave);
    Assert.isNull(breakdown.candidateYears);
    Assert.areEqual(5, breakdown.requiredYears);
  }

  @IsTest
  static void experienceBelowMinimumIsProportional() {
    // all skills (80) + 2.5 of 5 years (10) = 90
    Job_Applicant__c applicant = apply(
      getJob('Salesforce Developer'),
      2.5,
      new List<String>{ 'Apex', 'LWC', 'Java', 'Docker' }
    );

    Test.startTest();
    ScoringService.scoreApplicants(new Set<Id>{ applicant.Job__c });
    Test.stopTest();

    Assert.areEqual(90, getScore(applicant.Id));
  }

  @IsTest
  static void missingCriteriaAreLeftOut() {
    // Only must-have skills on the job: 1 of 2 matched = 50, whatever the years.
    Job__c job = TestDataFactory.createJob(
      'Must Have Only',
      null,
      new List<String>{ 'Apex', 'LWC' },
      null
    );
    Job_Applicant__c applicant = apply(job, 1, new List<String>{ 'Apex' });

    Test.startTest();
    ScoringService.scoreApplicants(new Set<Id>{ job.Id });
    Test.stopTest();

    Assert.areEqual(50, getScore(applicant.Id));
  }

  @IsTest
  static void jobWithoutCriteriaScoresZero() {
    Job__c job = TestDataFactory.createJob('Empty Job');
    Job_Applicant__c applicant = apply(job, 10, new List<String>{ 'Apex' });

    Test.startTest();
    ScoringService.scoreApplicants(new Set<Id>{ job.Id });
    Test.stopTest();

    Assert.areEqual(0, getScore(applicant.Id));
  }

  @IsTest
  static void alreadyScoredApplicantIsSkipped() {
    Job_Applicant__c applicant = apply(
      getJob('Salesforce Developer'),
      8,
      new List<String>{ 'Apex' }
    );
    applicant.Score__c = 77;
    update applicant;

    Test.startTest();
    List<ScoringService.Breakdown> breakdowns = ScoringService.scoreApplicants(
      new Set<Id>{ applicant.Job__c }
    );
    Test.stopTest();

    Assert.areEqual(0, breakdowns.size());
    Assert.areEqual(77, getScore(applicant.Id));
  }

  @IsTest
  static void invocableScoresBulkApplicantsPerJob() {
    Job__c job = getJob('Salesforce Developer');
    Job__c otherJob = TestDataFactory.createJob('Other Job');

    List<Candidate__c> candidates = new List<Candidate__c>();
    for (Integer i = 0; i < 200; i++) {
      Candidate__c candidate = TestDataFactory.newCandidate('Candidate ' + i);
      candidate.Years_Experience__c = 5;
      candidates.add(candidate);
    }
    insert candidates;
    List<Job_Applicant__c> applicants = new List<Job_Applicant__c>();
    for (Candidate__c candidate : candidates) {
      applicants.add(TestDataFactory.newApplicant(job.Id, candidate.Id));
    }
    applicants.add(TestDataFactory.newApplicant(otherJob.Id, candidates[0].Id));
    insert applicants;

    ScoringService.Request request = new ScoringService.Request();
    request.jobId = job.Id;
    ScoringService.Request otherRequest = new ScoringService.Request();
    otherRequest.jobId = otherJob.Id;

    Test.startTest();
    List<ScoringService.Result> results = ScoringService.scoreJobs(
      new List<ScoringService.Request>{ request, otherRequest }
    );
    Test.stopTest();

    Assert.areEqual(200, results[0].scoredCount);
    Assert.areEqual(1, results[1].scoredCount);
    // No skills matched (0 of 80) + 5 of 5 years (20) = 20
    Assert.areEqual(
      200,
      [
        SELECT COUNT()
        FROM Job_Applicant__c
        WHERE Job__c = :job.Id AND Score__c = 20
      ]
    );
  }

  @IsTest
  static void recruiterWithPermissionSetCanScore() {
    User recruiter = TestDataFactory.createRecruiter();
    Job_Applicant__c applicant = apply(
      getJob('Salesforce Developer'),
      8,
      new List<String>{ 'Apex', 'LWC' }
    );

    Test.startTest();
    System.runAs(recruiter) {
      ScoringService.scoreApplicants(new Set<Id>{ applicant.Job__c });
    }
    Test.stopTest();

    // 2/2 must (60) + 0/2 nice (0) + years (20) = 80
    Assert.areEqual(80, getScore(applicant.Id));
  }

  @IsTest
  static void userWithoutAccessGetsScoringException() {
    User noAccess = TestDataFactory.createUser();
    Job_Applicant__c applicant = apply(
      getJob('Salesforce Developer'),
      8,
      new List<String>{ 'Apex' }
    );

    Test.startTest();
    System.runAs(noAccess) {
      try {
        ScoringService.scoreApplicants(new Set<Id>{ applicant.Job__c });
        Assert.fail('Expected a ScoringException');
      } catch (ScoringService.ScoringException ex) {
        Assert.isTrue(ex.getMessage().startsWith('Scoring failed'));
      }
    }
    Test.stopTest();

    Assert.isNull(getScore(applicant.Id));
  }

  private static Job_Applicant__c apply(
    Job__c job,
    Decimal years,
    List<String> skillNames
  ) {
    Candidate__c candidate = TestDataFactory.createCandidate(
      'Test Candidate',
      years,
      skillNames
    );
    return TestDataFactory.createApplicant(job.Id, candidate.Id, null);
  }

  private static Job__c getJob(String name) {
    return [SELECT Id FROM Job__c WHERE Name = :name LIMIT 1];
  }

  @IsTest
  static void explainApplicantsSavesNothingUntilAsked() {
    Job__c job = getJob('Salesforce Developer');
    Job_Applicant__c scored = apply(
      job,
      8,
      new List<String>{ 'Apex', 'LWC', 'Java', 'Docker' }
    );
    Job_Applicant__c unscored = apply(job, null, new List<String>{ 'Apex' });
    ScoringService.scoreApplicants(new Set<Id>{ job.Id });
    delete [
      SELECT Id
      FROM Candidate_Skill__c
      WHERE Candidate__c = :scored.Candidate__c
    ];
    Job_Applicant__c newcomer = apply(
      job,
      5,
      new List<String>{ 'Apex', 'LWC' }
    );

    List<ScoringService.Breakdown> breakdowns = ScoringService.explainApplicants(
      job.Id,
      null
    );

    Assert.areEqual(3, breakdowns.size());
    Map<Id, ScoringService.Breakdown> byApplicant = new Map<Id, ScoringService.Breakdown>();
    for (ScoringService.Breakdown breakdown : breakdowns) {
      byApplicant.put(breakdown.jobApplicantId, breakdown);
    }
    // A saved score is kept (locked), even though the skills changed since.
    Assert.areEqual(100, byApplicant.get(scored.Id).score);
    Assert.isTrue(byApplicant.get(scored.Id).alreadyScored);
    Assert.isFalse(byApplicant.get(newcomer.Id).alreadyScored);
    Assert.isNull(getScore(newcomer.Id), 'nothing saved yet');

    ScoringService.saveScores(breakdowns);
    Assert.areEqual(80, getScore(newcomer.Id));

    List<ScoringService.Breakdown> onlyOne = ScoringService.explainApplicants(
      job.Id,
      new Set<Id>{ unscored.Candidate__c }
    );
    Assert.areEqual(1, onlyOne.size());
  }

  private static Decimal getScore(Id applicantId) {
    return [SELECT Score__c FROM Job_Applicant__c WHERE Id = :applicantId]
    .Score__c;
  }
}
