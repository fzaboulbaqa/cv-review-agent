@IsTest
private class CandidateRecommendationServiceTest {
  // Job: 5 years min, must have Apex + LWC, nice to have Docker.
  // Sara: Apex, LWC, Docker, 8 years = 100. Tom: Apex, 3 years = 30 + 0 + 12 = 42.
  @TestSetup
  static void setup() {
    Job__c job = TestDataFactory.createJob(
      'Senior Developer',
      5,
      new List<String>{ 'Apex', 'LWC' },
      new List<String>{ 'Docker' }
    );
    job.Description__c = 'Build apps';
    update job;
    Candidate__c sara = TestDataFactory.newCandidate('Sara');
    sara.Years_Experience__c = 8;
    sara.CV_Text__c = 'Sara CV';
    Candidate__c tom = TestDataFactory.newCandidate('Tom');
    tom.Years_Experience__c = 3;
    insert new List<Candidate__c>{ sara, tom };
    TestDataFactory.addCandidateSkills(
      sara.Id,
      new List<String>{ 'Apex', 'LWC', 'Docker' }
    );
    TestDataFactory.addCandidateSkills(tom.Id, new List<String>{ 'Apex' });
    insert TestDataFactory.newFlag(
      tom.Id,
      Constants.FLAG_MISSING,
      'Education',
      'Not found in CV.'
    );
    insert new List<Job_Applicant__c>{
      TestDataFactory.newApplicant(job.Id, sara.Id),
      TestDataFactory.newApplicant(job.Id, tom.Id)
    };
  }

  static Id jobId() {
    return [SELECT Id FROM Job__c LIMIT 1].Id;
  }

  static Job_Applicant__c applicant(String name) {
    return [
      SELECT Id, Score__c, Reasoning__c
      FROM Job_Applicant__c
      WHERE Candidate__r.Name = :name
    ];
  }

  @IsTest
  static void ranksExplainsAndSavesTheAiReasoning() {
    Id saraApplicant = applicant('Sara').Id;
    Id tomApplicant = applicant('Tom').Id;
    AiPromptFake fake = AiPromptFake.install()
      .answer(
        Constants.TEMPLATE_RECOMMEND,
        JSON.serialize(
          new Map<String, Object>{
            'recommendation' => 'Hire Sara.\nThank you for your time.',
            'applicants' => new List<Object>{
              new Map<String, Object>{
                'applicantId' => saraApplicant,
                'reasoning' => 'Strengths: all skills'
              },
              new Map<String, Object>{
                'applicantId' => tomApplicant,
                'reasoning' => 'Concerns: no LWC'
              },
              new Map<String, Object>{
                'applicantId' => 'not-an-id',
                'reasoning' => 'ignored'
              }
            }
          }
        )
      );

    CandidateRecommendationService.Recommendation result = CandidateRecommendationService.recommend(
      jobId(),
      null
    );

    Assert.isTrue(result.aiAvailable);
    Assert.areEqual(
      'Hire Sara.',
      result.recommendation,
      'courtesy line removed'
    );
    Assert.isTrue(result.hasStrongMatch);
    Assert.areEqual(saraApplicant, result.topApplicantId);
    Assert.areEqual(2, result.ranking.size());
    Assert.areEqual(100, result.ranking[0].score);
    Assert.areEqual(Constants.MATCH_STRONG, result.ranking[0].matchLevel);
    Assert.areEqual(42, result.ranking[1].score);
    Assert.areEqual(Constants.MATCH_WEAK, result.ranking[1].matchLevel);
    Assert.isTrue(
      result.ranking[1]
        .breakdown.contains('Must-have skills: 1 of 2 (has Apex; missing LWC)'),
      result.ranking[1].breakdown
    );
    Assert.isTrue(
      result.ranking[1]
        .breakdown.contains('Nice-to-have skills: 0 of 1 (missing Docker)'),
      result.ranking[1].breakdown
    );

    // The AI got the job, the scores and the CV / flags as data.
    String applicants = (String) fake.inputs[0].get('Applicants');
    Assert.isTrue(applicants.contains('Sara CV'));
    Assert.isTrue(applicants.contains('Missing Education'));
    Assert.isTrue(
      ((String) fake.inputs[0].get('Job'))
        .contains('Must-have skills: Apex, LWC')
    );

    Job_Applicant__c tom = applicant('Tom');
    Assert.areEqual(42, tom.Score__c, 'score saved');
    Assert.isTrue(
      tom.Reasoning__c.startsWith('Score: 42 (Weak match)'),
      tom.Reasoning__c
    );
    Assert.isTrue(tom.Reasoning__c.contains('Concerns: no LWC'));
  }

  @IsTest
  static void existingReasoningIsNotOverwritten() {
    Job_Applicant__c sara = applicant('Sara');
    sara.Reasoning__c = 'Written before';
    update sara;
    AiPromptFake.install()
      .answer(
        Constants.TEMPLATE_RECOMMEND,
        '{"recommendation": "Sara", "applicants": [{"applicantId": "' +
          sara.Id +
          '", "reasoning": "New"}]}'
      );

    CandidateRecommendationService.recommend(jobId(), null);

    Assert.areEqual('Written before', applicant('Sara').Reasoning__c);
  }

  @IsTest
  static void withoutTheAiTheRankingIsStillGiven() {
    AiPromptFake fake = AiPromptFake.install();
    fake.failing.add(Constants.TEMPLATE_RECOMMEND);

    CandidateRecommendationService.Recommendation result = CandidateRecommendationService.recommend(
      jobId(),
      new Set<Id>{ [SELECT Id FROM Candidate__c WHERE Name = 'Tom'].Id }
    );

    Assert.isFalse(result.aiAvailable);
    Assert.isTrue(result.recommendation.contains('not available'));
    Assert.areEqual(1, result.ranking.size(), 'only the selected candidate');
    Assert.isFalse(result.hasStrongMatch);
    Assert.areEqual(42, applicant('Tom').Score__c, 'scores are saved anyway');
    Assert.isNull(applicant('Tom').Reasoning__c, 'no reasoning without the AI');
  }

  @IsTest
  static void unknownJobOrNoApplicantsIsExplained() {
    AiPromptFake.install();
    Job__c empty = TestDataFactory.createJob('Empty Job');
    try {
      CandidateRecommendationService.recommend(empty.Id, null);
      Assert.fail('Expected a RecommendationException');
    } catch (CandidateRecommendationService.RecommendationException ex) {
      Assert.isTrue(ex.getMessage().contains('no matching applicants'));
    }
    delete empty;
    try {
      CandidateRecommendationService.recommend(empty.Id, null);
      Assert.fail('Expected a RecommendationException');
    } catch (CandidateRecommendationService.RecommendationException ex) {
      Assert.isTrue(ex.getMessage().contains('not found'));
    }
  }
}
