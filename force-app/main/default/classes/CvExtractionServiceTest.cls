@IsTest
private class CvExtractionServiceTest {
  // Job "Senior Developer": 5 years min, must have Apex + LWC, nice to have Docker.
  @TestSetup
  static void setup() {
    TestDataFactory.createJob(
      'Senior Developer',
      5,
      new List<String>{ 'Apex', 'LWC' },
      new List<String>{ 'Docker' }
    );
  }

  /** A typical AI answer: 10 years stated (conflict with the dates), JavaScript inferred, no phone, no education. */
  static String card(String email) {
    return '```json\n' +
      JSON.serialize(
        new Map<String, Object>{
          'fullName' => 'Karim El Fassi',
          'email' => email,
          'phone' => null,
          'country' => 'Morocco',
          'currentTitle' => 'Salesforce Developer',
          'summary' => 'Salesforce developer.',
          'yearsExperience' => 10,
          'experience' => 'Salesforce Developer, Nova (2022 - now)',
          'education' => null,
          'achievements' => 'N/A',
          'skills' => new List<Object>{
            new Map<String, Object>{
              'name' => 'apex',
              'inferred' => false,
              'evidence' => 'Apex REST'
            },
            new Map<String, Object>{
              'name' => 'LWC',
              'inferred' => false,
              'evidence' => 'LWC'
            },
            new Map<String, Object>{
              'name' => 'LWC',
              'inferred' => false,
              'evidence' => 'duplicate'
            },
            new Map<String, Object>{
              'name' => 'JavaScript',
              'inferred' => true,
              'evidence' => 'built LWCs'
            }
          },
          'flags' => new List<Object>{
            new Map<String, Object>{
              'type' => 'conflict',
              'field' => 'yearsExperience',
              'detail' => '10 stated, 6.7 from dates'
            },
            new Map<String, Object>{
              'type' => 'Opinion',
              'field' => 'summary',
              'detail' => 'dropped: unknown type'
            },
            new Map<String, Object>{
              'type' => 'Missing',
              'field' => 'experience',
              'detail' => 'No months for the dates'
            }
          }
        }
      ) +
      '\n```';
  }

  static Job__c job() {
    return [SELECT Id FROM Job__c LIMIT 1];
  }

  /** A candidate as the careers portal creates it: name, email, country typed in the form. */
  static Candidate__c portalCandidate() {
    Candidate__c candidate = TestDataFactory.newCandidate('Karim El Fassi');
    candidate.Email__c = 'karim@demo.com';
    candidate.Country__c = 'Spain';
    insert candidate;
    return candidate;
  }

  static ContentVersion upload(Id parentId, String fileName, String text) {
    return TestDataFactory.createFile(parentId, fileName, text);
  }

  static Map<String, List<Extraction_Flag__c>> flagsByType(Id candidateId) {
    Map<String, List<Extraction_Flag__c>> result = new Map<String, List<Extraction_Flag__c>>{
      Constants.FLAG_MISSING => new List<Extraction_Flag__c>(),
      Constants.FLAG_INFERRED => new List<Extraction_Flag__c>(),
      Constants.FLAG_CONFLICT => new List<Extraction_Flag__c>()
    };
    for (Extraction_Flag__c item : [
      SELECT Type__c, Field__c, Detail__c
      FROM Extraction_Flag__c
      WHERE Candidate__c = :candidateId
      ORDER BY Field__c
    ]) {
      result.get(item.Type__c).add(item);
    }
    return result;
  }

  @IsTest
  static void fillsTheEmptyFieldsAndKeepsTheTypedOnes() {
    AiPromptFake fake = AiPromptFake.install()
      .answer(Constants.TEMPLATE_EXTRACT_CARD, card('KARIM@Demo.com'));
    Candidate__c candidate = portalCandidate();
    upload(
      candidate.Id,
      'CV - Karim El Fassi - cv.txt',
      'Karim El Fassi, Salesforce Developer'
    );
    Job_Applicant__c applicant = TestDataFactory.createApplicant(
      job().Id,
      candidate.Id,
      null
    );
    // Another applicant of the same job, card not filled yet.
    Job_Applicant__c other = TestDataFactory.createApplicant(
      job().Id,
      TestDataFactory.createCandidate('Not Read Yet').Id,
      null
    );

    Test.startTest();
    CvExtractionService.FillResult result = CvExtractionService.fillCards(
      new List<Id>{ candidate.Id }
    );
    Test.stopTest();

    Assert.isNull(
      [SELECT Score__c FROM Job_Applicant__c WHERE Id = :other.Id].Score__c,
      'only the filled candidate is scored: a score is locked once set'
    );
    Assert.areEqual(1, result.outcomes.size());
    Assert.isTrue(result.notDone.isEmpty());
    CvExtractionService.Outcome outcome = result.outcomes[0];
    Assert.isTrue(outcome.success, outcome.message);
    Assert.isTrue(
      outcome.message.startsWith(
        'Card of Karim El Fassi: 4 field(s) filled, 3 skill(s) added'
      ),
      outcome.message
    );

    Candidate__c saved = [
      SELECT
        Name,
        Email__c,
        Country__c,
        Phone__c,
        Current_Title__c,
        Summary__c,
        Experience__c,
        Years_Experience__c,
        CV_Text__c,
        Achievements__c
      FROM Candidate__c
      WHERE Id = :candidate.Id
    ];
    // Filled from the CV: title, summary, experience, years.
    Assert.areEqual('Salesforce Developer', saved.Current_Title__c);
    Assert.areEqual('Salesforce developer.', saved.Summary__c);
    Assert.isNotNull(saved.Experience__c);
    Assert.areEqual(10, saved.Years_Experience__c);
    Assert.areEqual('Karim El Fassi, Salesforce Developer', saved.CV_Text__c);
    Assert.isNull(saved.Achievements__c, '"N/A" means no value');
    // Typed in the portal: kept, the CV disagrees on the country only.
    Assert.areEqual('Spain', saved.Country__c);
    Assert.areEqual('karim@demo.com', saved.Email__c);

    // Skills: apex matched case-insensitively, LWC once, JavaScript created.
    Assert.areEqual(
      3,
      [
        SELECT COUNT()
        FROM Candidate_Skill__c
        WHERE Candidate__c = :candidate.Id
      ]
    );
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Skill__c WHERE Name = 'JavaScript']
    );
    Assert.areEqual(1, [SELECT COUNT() FROM Skill__c WHERE Name = 'Apex']);

    Map<String, List<Extraction_Flag__c>> flags = flagsByType(candidate.Id);
    Set<String> conflicts = fields(flags.get(Constants.FLAG_CONFLICT));
    Assert.areEqual(
      new Set<String>{ 'Country', 'Years of Experience' },
      conflicts
    );
    Assert.areEqual(1, flags.get(Constants.FLAG_INFERRED).size());
    Assert.isTrue(
      flags.get(Constants.FLAG_INFERRED)[0].Detail__c.contains('JavaScript')
    );
    // Experience flagged by the AI; Phone and Education empty on the record and in the CV.
    Assert.areEqual(
      new Set<String>{ 'Experience', 'Phone', 'Education' },
      fields(flags.get(Constants.FLAG_MISSING))
    );

    // must-have 2/2 (60) + nice-to-have 0/1 (0) + 10 of 5 years (20) = 80 / 100.
    Assert.areEqual(
      80,
      [SELECT Score__c FROM Job_Applicant__c WHERE Id = :applicant.Id].Score__c
    );
    Assert.areEqual(
      0,
      fake.count(Constants.TEMPLATE_READ_CV),
      'a .txt CV needs no AI reading'
    );
  }

  @IsTest
  static void readingAgainKeepsSkillsAndValuesAndReplacesFlags() {
    Candidate__c candidate = TestDataFactory.newCandidate('Karim El Fassi');
    candidate.Email__c = 'karim@demo.com';
    candidate.Phone__c = '600';
    candidate.Years_Experience__c = 6;
    candidate.Current_Title__c = 'Lead Developer';
    insert candidate;
    TestDataFactory.addCandidateSkills(
      candidate.Id,
      new List<String>{ 'Cobol', 'Apex' }
    );
    insert TestDataFactory.newFlag(
      candidate.Id,
      Constants.FLAG_MISSING,
      'Old',
      'old'
    );
    upload(candidate.Id, 'CV - Karim.txt', 'CV text');
    AiPromptFake.install()
      .answer(Constants.TEMPLATE_EXTRACT_CARD, card('karim@demo.com'));

    CvExtractionService.Outcome outcome = CvExtractionService.fillCards(
        new List<Id>{ candidate.Id }
      )
      .outcomes[0];

    Assert.isTrue(outcome.success, outcome.message);
    Assert.areEqual(
      2,
      outcome.skillsAdded,
      'LWC and JavaScript; Apex was there'
    );
    Assert.areEqual(
      4,
      [
        SELECT COUNT()
        FROM Candidate_Skill__c
        WHERE Candidate__c = :candidate.Id
      ],
      'Cobol stays'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Extraction_Flag__c WHERE Field__c = 'Old'],
      'old flags replaced'
    );
    Candidate__c saved = [
      SELECT Phone__c, Years_Experience__c, Current_Title__c
      FROM Candidate__c
      WHERE Id = :candidate.Id
    ];
    Assert.areEqual('600', saved.Phone__c);
    Assert.areEqual(6, saved.Years_Experience__c);
    Assert.areEqual('Lead Developer', saved.Current_Title__c);
    Assert.isTrue(
      fields(flagsByType(candidate.Id).get(Constants.FLAG_CONFLICT))
        .containsAll(new Set<String>{ 'Years of Experience', 'Current Title' })
    );
    Assert.isFalse(
      fields(flagsByType(candidate.Id).get(Constants.FLAG_MISSING))
        .contains('Phone'),
      'phone is on the record'
    );
  }

  @IsTest
  static void theCvIsPreferredOverOtherDocuments() {
    Candidate__c candidate = portalCandidate();
    upload(candidate.Id, 'CV - Karim El Fassi - resume.txt', 'the real CV');
    upload(
      candidate.Id,
      'Document - Karim El Fassi - cover letter.txt',
      'a cover letter'
    );
    upload(candidate.Id, 'photo.png', 'image');
    AiPromptFake fake = AiPromptFake.install()
      .answer(Constants.TEMPLATE_EXTRACT_CARD, card('karim@demo.com'));

    CvExtractionService.fillCards(new List<Id>{ candidate.Id });

    Assert.areEqual('the real CV', fake.inputs[0].get('CvText'));
  }

  @IsTest
  static void anUnreadableCvKeepsTheCard() {
    Candidate__c candidate = TestDataFactory.newCandidate('Lina');
    candidate.Current_Title__c = 'Developer';
    insert candidate;
    upload(candidate.Id, 'lina.doc', 'binary');
    AiPromptFake fake = AiPromptFake.install();

    CvExtractionService.Outcome outcome = CvExtractionService.fillCards(
        new List<Id>{ candidate.Id }
      )
      .outcomes[0];

    Assert.isTrue(outcome.message.contains('.doc file'), outcome.message);
    Assert.areEqual(0, fake.calls.size());
    Assert.areEqual(
      'Developer',
      [SELECT Current_Title__c FROM Candidate__c WHERE Id = :candidate.Id]
      .Current_Title__c
    );
    List<Extraction_Flag__c> flags = [
      SELECT Field__c
      FROM Extraction_Flag__c
      WHERE Candidate__c = :candidate.Id
    ];
    Assert.areEqual(1, flags.size());
    Assert.areEqual('CV', flags[0].Field__c);
  }

  @IsTest
  static void aiFailureIsReportedAndNothingChanges() {
    Candidate__c candidate = portalCandidate();
    upload(candidate.Id, 'CV - Karim.txt', 'CV text');
    AiPromptFake fake = AiPromptFake.install();
    fake.failing.add(Constants.TEMPLATE_EXTRACT_CARD);

    CvExtractionService.Outcome outcome = CvExtractionService.fillCards(
        new List<Id>{ candidate.Id }
      )
      .outcomes[0];

    Assert.isFalse(outcome.success);
    Assert.isTrue(outcome.message.contains('could not read'), outcome.message);
    Assert.isNull(
      [SELECT CV_Text__c FROM Candidate__c WHERE Id = :candidate.Id].CV_Text__c
    );
  }

  @IsTest
  static void missingCvsAndUnknownCandidatesAreExplained() {
    Candidate__c candidate = TestDataFactory.createCandidate('Tom');
    Id unknownId =
      Candidate__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001AAA';
    AiPromptFake.install();

    List<CvExtractionService.Outcome> outcomes = CvExtractionService.fillCards(
        new List<Id>{ candidate.Id, unknownId }
      )
      .outcomes;

    Assert.isTrue(
      outcomes[0].message.contains('has no CV file'),
      outcomes[0].message
    );
    Assert.isTrue(
      outcomes[1].message.contains('not found'),
      outcomes[1].message
    );
  }

  @IsTest
  static void unbelievableYearsAreDroppedAndReported() {
    Candidate__c candidate = portalCandidate();
    upload(candidate.Id, 'CV - Karim.txt', 'CV text');
    String answer = card('karim@demo.com')
      .replace('"yearsExperience":10', '"yearsExperience":99');
    AiPromptFake.install().answer(Constants.TEMPLATE_EXTRACT_CARD, answer);

    CvExtractionService.fillCards(new List<Id>{ candidate.Id });

    Assert.isNull(
      [SELECT Years_Experience__c FROM Candidate__c WHERE Id = :candidate.Id]
      .Years_Experience__c
    );
    Assert.isTrue(
      fields(flagsByType(candidate.Id).get(Constants.FLAG_MISSING))
        .contains('Years of Experience')
    );
  }

  @IsTest
  static void candidatesOverTheLimitAreListedAsNotDone() {
    List<Id> candidateIds = new List<Id>();
    for (
      Integer i = 0; i <= CvExtractionService.MAX_CANDIDATES_PER_REQUEST; i++
    ) {
      Candidate__c candidate = TestDataFactory.createCandidate(
        'Candidate ' + i
      );
      upload(candidate.Id, 'CV ' + i + '.txt', 'CV ' + i);
      candidateIds.add(candidate.Id);
    }
    AiPromptFake fake = AiPromptFake.install()
      .answer(Constants.TEMPLATE_EXTRACT_CARD, card(null));

    CvExtractionService.FillResult result = CvExtractionService.fillCards(
      candidateIds
    );

    Assert.areEqual(
      CvExtractionService.MAX_CANDIDATES_PER_REQUEST,
      result.outcomes.size()
    );
    Assert.areEqual(
      new List<String>{
        'Candidate ' + CvExtractionService.MAX_CANDIDATES_PER_REQUEST
      },
      result.notDone
    );
    Assert.areEqual(
      CvExtractionService.MAX_CANDIDATES_PER_REQUEST,
      fake.count(Constants.TEMPLATE_EXTRACT_CARD)
    );
  }

  @IsTest
  static void jobApplicantsWithoutACardFromTheirCvAreDone() {
    Id jobId = job().Id;
    Candidate__c fresh = portalCandidate();
    upload(fresh.Id, 'CV - Karim.txt', 'CV text');
    Candidate__c done = TestDataFactory.newCandidate('Sara');
    done.CV_Text__c = 'Already read';
    insert done;
    TestDataFactory.createApplicant(jobId, fresh.Id, null);
    TestDataFactory.createApplicant(jobId, done.Id, null);
    AiPromptFake.install()
      .answer(Constants.TEMPLATE_EXTRACT_CARD, card('karim@demo.com'));

    CvExtractionService.FillResult result = CvExtractionService.fillJobApplicants(
      jobId
    );

    Assert.areEqual(1, result.outcomes.size());
    Assert.areEqual(fresh.Id, result.outcomes[0].candidateId);
    Assert.areEqual(1, result.alreadyDoneCount);
  }

  static Set<String> fields(List<Extraction_Flag__c> flags) {
    Set<String> result = new Set<String>();
    for (Extraction_Flag__c item : flags) {
      result.add(item.Field__c);
    }
    return result;
  }
}
