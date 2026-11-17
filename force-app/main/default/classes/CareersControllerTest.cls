@IsTest
private class CareersControllerTest {
  @TestSetup
  static void setup() {
    Job__c dev = TestDataFactory.newJob('Salesforce Developer');
    dev.Location__c = 'Morocco - Casablanca';
    dev.Min_Years_Experience__c = 5;
    dev.Due_Date__c = Date.today().addDays(10);
    dev.Description__c = 'Build Apex and LWC.';
    Job__c analyst = TestDataFactory.newJob('Data Analyst');
    analyst.Location__c = 'Remote';
    analyst.Min_Years_Experience__c = 2;
    analyst.Due_Date__c = Date.today().addDays(20);
    Job__c noDueDate = TestDataFactory.newJob('Open Application');
    noDueDate.Location__c = 'Remote';
    Job__c closed = TestDataFactory.newJob('Closed Job');
    closed.Location__c = 'Paris';
    closed.Due_Date__c = Date.today().addDays(-1);
    insert new List<Job__c>{ dev, analyst, noDueDate, closed };

    TestDataFactory.addJobSkills(
      dev.Id,
      new List<String>{ 'Apex' },
      Constants.IMPORTANCE_MUST_HAVE
    );
    TestDataFactory.addJobSkills(
      dev.Id,
      new List<String>{ 'SQL' },
      Constants.IMPORTANCE_NICE_TO_HAVE
    );
    TestDataFactory.addJobSkills(
      analyst.Id,
      new List<String>{ 'SQL' },
      Constants.IMPORTANCE_MUST_HAVE
    );
    TestDataFactory.addJobSkills(
      closed.Id,
      new List<String>{ 'Apex' },
      Constants.IMPORTANCE_MUST_HAVE
    );
  }

  @IsTest
  static void listsOpenJobsOnlySoonestFirst() {
    CareersController.JobPage page = CareersController.searchJobs(
      null,
      null,
      null,
      null,
      1
    );

    Assert.areEqual(3, page.total);
    Assert.areEqual(
      new List<String>{
        'Salesforce Developer',
        'Data Analyst',
        'Open Application'
      },
      titles(page)
    );
    Assert.areEqual('Morocco - Casablanca', page.jobs[0].location);
  }

  @IsTest
  static void keywordMatchesTitleLocationOrSkill() {
    Assert.areEqual(
      new List<String>{ 'Data Analyst' },
      titles(CareersController.searchJobs('analyst', null, null, null, 1))
    );
    Assert.areEqual(
      new List<String>{ 'Salesforce Developer' },
      titles(CareersController.searchJobs('casablanca', null, null, null, 1))
    );
    // "Apex" is a skill of the developer job and of the closed job: only the open one comes back.
    Assert.areEqual(
      new List<String>{ 'Salesforce Developer' },
      titles(CareersController.searchJobs('apex', null, null, null, 1))
    );
    Assert.areEqual(
      0,
      CareersController.searchJobs('100%', null, null, null, 1).total
    );
  }

  @IsTest
  static void filtersByLocationSkillAndYears() {
    Assert.areEqual(
      new List<String>{ 'Data Analyst', 'Open Application' },
      titles(
        CareersController.searchJobs(
          null,
          new List<String>{ 'Remote' },
          null,
          null,
          1
        )
      )
    );
    Assert.areEqual(
      new List<String>{ 'Salesforce Developer', 'Data Analyst' },
      titles(
        CareersController.searchJobs(
          null,
          null,
          new List<String>{ 'SQL' },
          null,
          1
        )
      )
    );
    // 3 years: the developer job needs 5.
    Assert.areEqual(
      new List<String>{ 'Data Analyst', 'Open Application' },
      titles(CareersController.searchJobs(null, null, null, 3, 1))
    );
  }

  @IsTest
  static void pagesResults() {
    List<Job__c> more = new List<Job__c>();
    for (Integer i = 0; i < CareersController.PAGE_SIZE; i++) {
      more.add(TestDataFactory.newJob('Extra ' + i));
    }
    insert more;

    CareersController.JobPage second = CareersController.searchJobs(
      null,
      null,
      null,
      null,
      2
    );

    Assert.areEqual(CareersController.PAGE_SIZE + 3, second.total);
    Assert.areEqual(3, second.jobs.size());
  }

  @IsTest
  static void filterOptionsComeFromOpenJobs() {
    CareersController.FilterOptions options = CareersController.getFilterOptions();

    Assert.areEqual(
      new List<String>{ 'Morocco - Casablanca', 'Remote' },
      options.locations
    );
    Assert.areEqual(new List<String>{ 'Apex', 'SQL' }, options.skills);
  }

  @IsTest
  static void returnsJobDetailWithSkills() {
    Id jobId = [SELECT Id FROM Job__c WHERE Name = 'Salesforce Developer'].Id;

    CareersController.JobDetail detail = CareersController.getJob(jobId);

    Assert.areEqual('Salesforce Developer', detail.job.title);
    Assert.areEqual('Build Apex and LWC.', detail.description);
    Assert.areEqual(new List<String>{ 'Apex' }, detail.mustHaveSkills);
    Assert.areEqual(new List<String>{ 'SQL' }, detail.niceToHaveSkills);
  }

  @IsTest
  static void closedJobIsNotShown() {
    Id jobId = [SELECT Id FROM Job__c WHERE Name = 'Closed Job'].Id;
    try {
      CareersController.getJob(jobId);
      Assert.fail('Expected an AuraHandledException');
    } catch (AuraHandledException ex) {
      Assert.areEqual('This job is no longer open.', ex.getMessage());
    }
  }

  @IsTest
  static void escapesLikeWildcards() {
    Assert.areEqual(
      '100\\%\\_a\\\\b',
      CareersController.escapeLike('100%_a\\b')
    );
  }

  @IsTest
  static void applyDelegatesToTheService() {
    CareersApplicationService.Result result = CareersController.apply(
      new CareersApplicationService.Application()
    );

    Assert.isFalse(result.success);
    Assert.areEqual('Please choose a job to apply to.', result.message);
  }

  private static List<String> titles(CareersController.JobPage page) {
    List<String> titles = new List<String>();
    for (CareersController.JobSummary job : page.jobs) {
      titles.add(job.title);
    }
    return titles;
  }
}
