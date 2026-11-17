@IsTest
private class CandidateQuestionServiceTest {
  @TestSetup
  static void setup() {
    Job__c job = TestDataFactory.createJob('Developer');
    Candidate__c sara = TestDataFactory.newCandidate('Sara');
    sara.CV_Text__c = 'Sara: 8 years, Docker';
    Candidate__c tom = TestDataFactory.newCandidate('Tom');
    insert new List<Candidate__c>{ sara, tom };
    TestDataFactory.createApplicant(job.Id, sara.Id, null);
  }

  @IsTest
  static void answersFromTheSelectedCvs() {
    AiPromptFake fake = AiPromptFake.install()
      .answer(Constants.TEMPLATE_ANSWER_QUESTION, 'Sara: "Docker"');
    List<Id> ids = new List<Id>(
      new Map<Id, Candidate__c>([SELECT Id FROM Candidate__c]).keySet()
    );

    CandidateQuestionService.Answer answer = CandidateQuestionService.ask(
      'Who knows Docker?',
      ids,
      null
    );

    Assert.areEqual('Sara: "Docker"', answer.answer);
    Assert.areEqual(2, answer.candidateNames.size());
    String sources = (String) fake.inputs[0].get('Candidates');
    Assert.isTrue(sources.contains('[1] Candidate: Sara'));
    Assert.isTrue(sources.contains('Sara: 8 years, Docker'));
    Assert.isTrue(sources.contains('No CV text'), 'Tom has no CV text');
    Assert.isTrue(answer.note.contains('Tom has no CV text'));
  }

  @IsTest
  static void jobMeansItsApplicants() {
    AiPromptFake.install().answer(Constants.TEMPLATE_ANSWER_QUESTION, 'ok');
    CandidateQuestionService.Answer answer = CandidateQuestionService.ask(
      'Who knows Docker?',
      new List<Id>(),
      [SELECT Id FROM Job__c LIMIT 1].Id
    );
    Assert.areEqual(new List<String>{ 'Sara' }, answer.candidateNames);
    Assert.isNull(answer.note);
  }

  @IsTest
  static void noSelectionSearchesAllCandidatesAndCutsLongCvs() {
    Candidate__c sara = [SELECT Id FROM Candidate__c WHERE Name = 'Sara'];
    sara.CV_Text__c = 'x'.repeat(CandidateQuestionService.MAX_CV_CHARS + 5);
    update sara;
    AiPromptFake.install().answer(Constants.TEMPLATE_ANSWER_QUESTION, 'ok');

    CandidateQuestionService.Answer answer = CandidateQuestionService.ask(
      'Anyone?',
      new List<Id>(),
      null
    );

    Assert.areEqual(2, answer.candidateNames.size());
    Assert.isTrue(answer.note.contains('the CV of Sara was cut'));
  }

  @IsTest
  static void questionAndCandidatesAreRequired() {
    AiPromptFake.install();
    try {
      CandidateQuestionService.ask(' ', new List<Id>(), null);
      Assert.fail('Expected a QuestionException');
    } catch (CandidateQuestionService.QuestionException ex) {
      Assert.isTrue(ex.getMessage().contains('ask a question'));
    }
    Job__c empty = TestDataFactory.createJob('Empty');
    try {
      CandidateQuestionService.ask('Who?', new List<Id>(), empty.Id);
      Assert.fail('Expected a QuestionException');
    } catch (CandidateQuestionService.QuestionException ex) {
      Assert.isTrue(ex.getMessage().contains('no applicants'));
    }
  }
}
