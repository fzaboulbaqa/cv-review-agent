@IsTest
private class CareersControllerTest {
  @TestSetup
  static void setup() {
    Skill__c apex = new Skill__c(Name = 'Apex');
    Skill__c sql = new Skill__c(Name = 'SQL');
    Job__c dev = new Job__c(
      Name = 'Salesforce Developer',
      Location__c = 'Morocco - Casablanca',
      Min_Years_Experience__c = 5,
      Due_Date__c = Date.today().addDays(10),
      Description__c = 'Build Apex and LWC.'
    );
    Job__c analyst = new Job__c(
      Name = 'Data Analyst',
      Location__c = 'Remote',
      Min_Years_Experience__c = 2,
      Due_Date__c = Date.today().addDays(20)
    );
    Job__c noDueDate = new Job__c(
      Name = 'Open Application',
      Location__c = 'Remote'
    );
    Job__c closed = new Job__c(
      Name = 'Closed Job',
      Location__c = 'Paris',
      Due_Date__c = Date.today().addDays(-1)
    );
    insert new List<SObject>{ apex, sql, dev, analyst, noDueDate, closed };
    insert new List<Job_Skill__c>{
      new Job_Skill__c(
        Job__c = dev.Id,
        Skill__c = apex.Id,
        Importance__c = 'Must Have'
      ),
      new Job_Skill__c(
        Job__c = dev.Id,
        Skill__c = sql.Id,
        Importance__c = 'Nice To Have'
      ),
      new Job_Skill__c(
        Job__c = analyst.Id,
        Skill__c = sql.Id,
        Importance__c = 'Must Have'
      ),
      new Job_Skill__c(
        Job__c = closed.Id,
        Skill__c = apex.Id,
        Importance__c = 'Must Have'
      )
    };
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
      more.add(new Job__c(Name = 'Extra ' + i));
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
