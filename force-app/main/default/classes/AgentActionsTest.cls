/** The agent actions: input checks, messages, and that they call the services. */
@IsTest
private class AgentActionsTest {
  @TestSetup
  static void setup() {
    Job__c job = TestDataFactory.newJob('Salesforce Developer');
    job.Location__c = 'Casablanca';
    job.Due_Date__c = Date.today().addDays(10);
    insert job;
    TestDataFactory.addJobSkills(
      job.Id,
      new List<String>{ 'Apex' },
      Constants.IMPORTANCE_MUST_HAVE
    );
    Candidate__c sara = TestDataFactory.newCandidate('Sara Haddad');
    sara.Current_Title__c = 'Lead Developer';
    sara.Years_Experience__c = 8;
    sara.CV_Text__c = 'Sara CV';
    insert sara;
    TestDataFactory.addCandidateSkills(sara.Id, new List<String>{ 'Apex' });
    TestDataFactory.createApplicant(job.Id, sara.Id, null);
  }

  static Job__c job() {
    return [SELECT Id FROM Job__c LIMIT 1];
  }

  static Candidate__c sara() {
    return [SELECT Id FROM Candidate__c LIMIT 1];
  }

  static Job_Applicant__c applicant() {
    return [SELECT Id FROM Job_Applicant__c LIMIT 1];
  }

  @IsTest
  static void findJobs() {
    AgentFindJobs.Request request = new AgentFindJobs.Request();
    request.searchText = 'salesforce';
    String message = AgentFindJobs.find(
        new List<AgentFindJobs.Request>{ request }
      )[0]
      .message;
    Assert.isTrue(
      message.contains('Salesforce Developer | Casablanca | 1 applicant(s)'),
      message
    );
    Assert.isTrue(message.contains('jobId: ' + job().Id));

    request.searchText = 'nothing like this';
    Assert.isTrue(
      AgentFindJobs.find(new List<AgentFindJobs.Request>{ request })[0]
        .message.startsWith('No job found')
    );
  }

  @IsTest
  static void findCandidatesByTextSkillOrJob() {
    AgentFindCandidates.Request request = new AgentFindCandidates.Request();
    request.searchText = 'apex';
    String message = AgentFindCandidates.find(
        new List<AgentFindCandidates.Request>{ request }
      )[0]
      .message;
    Assert.isTrue(
      message.contains('Sara Haddad | Lead Developer | 8.0 years'),
      message
    );
    Assert.isTrue(message.contains('candidateId: ' + sara().Id));

    request.searchText = null;
    request.jobId = job().Id;
    message = AgentFindCandidates.find(
        new List<AgentFindCandidates.Request>{ request }
      )[0]
      .message;
    Assert.isTrue(message.contains('score: not scored'), message);
    Assert.isTrue(message.contains('applicantId: ' + applicant().Id));

    request.jobId = 'Salesforce Developer';
    message = AgentFindCandidates.find(
        new List<AgentFindCandidates.Request>{ request }
      )[0]
      .message;
    Assert.isTrue(message.startsWith('I need the job record id'), message);

    request.jobId = null;
    message = AgentFindCandidates.find(
        new List<AgentFindCandidates.Request>{ request }
      )[0]
      .message;
    Assert.isTrue(message.contains('name, title or skill'), message);
  }

  @IsTest
  static void createCandidateCard() {
    AiPromptFake.install();
    AgentCreateCandidateCard.Request request = new AgentCreateCandidateCard.Request();
    request.candidateIds = sara().Id + ', ' + sara().Id;
    String message = AgentCreateCandidateCard.create(
        new List<AgentCreateCandidateCard.Request>{ request }
      )[0]
      .message;
    Assert.areEqual(
      '- Sara Haddad has no CV file. Upload one in the Files of the candidate first.',
      message
    );

    // A job: Sara already has CV text, so nothing to do.
    request.candidateIds = null;
    request.jobId = job().Id;
    message = AgentCreateCandidateCard.create(
        new List<AgentCreateCandidateCard.Request>{ request }
      )[0]
      .message;
    Assert.isTrue(
      message.contains('1 applicant(s) already have a card'),
      message
    );

    Job__c empty = TestDataFactory.createJob('Empty');
    request.jobId = empty.Id;
    message = AgentCreateCandidateCard.create(
        new List<AgentCreateCandidateCard.Request>{ request }
      )[0]
      .message;
    Assert.areEqual('This job has no applicants yet.', message);

    request.jobId = null;
    message = AgentCreateCandidateCard.create(
        new List<AgentCreateCandidateCard.Request>{ request }
      )[0]
      .message;
    Assert.isTrue(message.startsWith('Which candidate?'), message);

    List<String> ids = new List<String>();
    for (
      Integer i = 0; i <= CvExtractionService.MAX_CANDIDATES_PER_REQUEST; i++
    ) {
      ids.add(TestDataFactory.createCandidate('Extra ' + i).Id);
    }
    request.candidateIds = String.join(ids, ',');
    message = AgentCreateCandidateCard.create(
        new List<AgentCreateCandidateCard.Request>{ request }
      )[0]
      .message;
    Assert.isTrue(
      message.contains(
        'Not done yet (at most 3 cards per request): Extra 3. Ask again'
      ),
      message
    );

    request.candidateIds = job().Id;
    message = AgentCreateCandidateCard.create(
        new List<AgentCreateCandidateCard.Request>{ request }
      )[0]
      .message;
    Assert.isTrue(
      message.startsWith('I need the candidate record id'),
      message
    );
  }

  @IsTest
  static void askAboutCandidates() {
    AiPromptFake.install()
      .answer(Constants.TEMPLATE_ANSWER_QUESTION, 'Sara Haddad: "Sara CV"');
    AgentAskAboutCandidates.Request request = new AgentAskAboutCandidates.Request();
    request.question = 'What does Sara know?';
    request.candidateIds = sara().Id;
    Assert.areEqual(
      'Sara Haddad: "Sara CV"',
      AgentAskAboutCandidates.ask(
          new List<AgentAskAboutCandidates.Request>{ request }
        )[0]
        .answer
    );

    request.question = '';
    Assert.isTrue(
      AgentAskAboutCandidates.ask(
          new List<AgentAskAboutCandidates.Request>{ request }
        )[0]
        .answer.contains('ask a question')
    );
  }

  @IsTest
  static void askReportsAiFailures() {
    AiPromptFake fake = AiPromptFake.install();
    fake.failing.add(Constants.TEMPLATE_ANSWER_QUESTION);
    AgentAskAboutCandidates.Request request = new AgentAskAboutCandidates.Request();
    request.question = 'Anything?';
    String answer = AgentAskAboutCandidates.ask(
        new List<AgentAskAboutCandidates.Request>{ request }
      )[0]
      .answer;
    Assert.isTrue(answer.startsWith('Sorry, "Answer Question" failed'), answer);
  }

  @IsTest
  static void compareAndRecommend() {
    AiPromptFake.install()
      .answer(
        Constants.TEMPLATE_RECOMMEND,
        '{"recommendation": "Sara is the best option.", "applicants": []}'
      );
    AgentCompareCandidates.Request request = new AgentCompareCandidates.Request();
    request.jobId = job().Id;
    AgentCompareCandidates.Result result = AgentCompareCandidates.compare(
      new List<AgentCompareCandidates.Request>{ request }
    )[0];
    Assert.isTrue(
      result.message.contains('Sara is the best option.'),
      result.message
    );
    Assert.isTrue(
      result.message.contains(
        '1. Sara Haddad: 100/100, Strong match (applicantId: ' +
          applicant().Id +
          ')'
      ),
      result.message
    );
    Assert.areEqual(applicant().Id, result.topApplicantId);

    Job__c empty = TestDataFactory.createJob('Empty');
    request.jobId = empty.Id;
    result = AgentCompareCandidates.compare(
      new List<AgentCompareCandidates.Request>{ request }
    )[0];
    Assert.isTrue(
      result.message.contains('no matching applicants'),
      result.message
    );
  }

  @IsTest
  static void compareSaysWhenThereIsNoStrongMatch() {
    Candidate__c sara = sara();
    delete [SELECT Id FROM Candidate_Skill__c WHERE Candidate__c = :sara.Id];
    AiPromptFake.install()
      .answer(
        Constants.TEMPLATE_RECOMMEND,
        '{"recommendation": "Best available: Sara.", "applicants": []}'
      );
    AgentCompareCandidates.Request request = new AgentCompareCandidates.Request();
    request.jobId = job().Id;
    String message = AgentCompareCandidates.compare(
        new List<AgentCompareCandidates.Request>{ request }
      )[0]
      .message;
    Assert.isTrue(message.contains('No applicant is a strong match'), message);
  }

  @IsTest
  static void bookmarkOnceWithNotes() {
    AgentBookmarkCandidate.Request request = new AgentBookmarkCandidate.Request();
    request.applicantId = applicant().Id;
    request.notes = 'Strong on Apex';

    AgentBookmarkCandidate.Result first = AgentBookmarkCandidate.bookmark(
      new List<AgentBookmarkCandidate.Request>{ request }
    )[0];
    AgentBookmarkCandidate.Result second = AgentBookmarkCandidate.bookmark(
      new List<AgentBookmarkCandidate.Request>{ request }
    )[0];

    Assert.isTrue(
      first.message.startsWith(
        'Bookmarked Sara Haddad for Salesforce Developer'
      ),
      first.message
    );
    Assert.isTrue(
      second.message.startsWith('You had already bookmarked'),
      second.message
    );
    Assert.areEqual(first.bookmarkId, second.bookmarkId);
    Bookmark__c bookmark = [SELECT Notes__c FROM Bookmark__c];
    Assert.areEqual('Strong on Apex', bookmark.Notes__c);

    request.applicantId = job().Id;
    Assert.isTrue(
      AgentBookmarkCandidate.bookmark(
          new List<AgentBookmarkCandidate.Request>{ request }
        )[0]
        .message.startsWith('I need the job applicant record id')
    );
  }
}
