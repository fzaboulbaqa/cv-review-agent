@IsTest
private class ScoringServiceTest {
    // Job "Salesforce Developer": 5 years min, must have Apex + LWC, nice to have Java + Docker.
    @TestSetup
    static void setup() {
        Map<String, Skill__c> skills = new Map<String, Skill__c>();
        for (String name : new List<String>{ 'Apex', 'LWC', 'Java', 'Docker' }) {
            skills.put(name, new Skill__c(Name = name));
        }
        insert skills.values();

        Job__c job = new Job__c(Name = 'Salesforce Developer', Min_Years_Experience__c = 5);
        insert job;
        insert new List<Job_Skill__c>{
            new Job_Skill__c(Job__c = job.Id, Skill__c = skills.get('Apex').Id, Importance__c = 'Must Have'),
            new Job_Skill__c(Job__c = job.Id, Skill__c = skills.get('LWC').Id, Importance__c = 'Must Have'),
            new Job_Skill__c(Job__c = job.Id, Skill__c = skills.get('Java').Id, Importance__c = 'Nice To Have'),
            new Job_Skill__c(Job__c = job.Id, Skill__c = skills.get('Docker').Id, Importance__c = 'Nice To Have')
        };
    }

    @IsTest
    static void fullMatchScores100() {
        Job_Applicant__c applicant = apply(getJob('Salesforce Developer'), 8, new List<String>{ 'Apex', 'LWC', 'Java', 'Docker' });

        Test.startTest();
        List<ScoringService.Breakdown> breakdowns = ScoringService.scoreApplicants(new Set<Id>{ applicant.Job__c });
        Test.stopTest();

        Assert.areEqual(1, breakdowns.size());
        Assert.areEqual(100, breakdowns[0].score);
        Assert.areEqual(0, breakdowns[0].missingMustHave.size());
        Assert.areEqual(100, getScore(applicant.Id));
    }

    @IsTest
    static void partialMatchWithUnknownYears() {
        // 1/2 must (30) + 1/2 nice (10) + unknown years (0) = 40
        Job_Applicant__c applicant = apply(getJob('Salesforce Developer'), null, new List<String>{ 'Apex', 'Java' });

        Test.startTest();
        ScoringService.Breakdown breakdown = ScoringService.scoreApplicants(new Set<Id>{ applicant.Job__c })[0];
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
        Job_Applicant__c applicant = apply(getJob('Salesforce Developer'), 2.5, new List<String>{ 'Apex', 'LWC', 'Java', 'Docker' });

        Test.startTest();
        ScoringService.scoreApplicants(new Set<Id>{ applicant.Job__c });
        Test.stopTest();

        Assert.areEqual(90, getScore(applicant.Id));
    }

    @IsTest
    static void missingCriteriaAreLeftOut() {
        // Only must-have skills on the job: 1 of 2 matched = 50, whatever the years.
        Job__c job = new Job__c(Name = 'Must Have Only');
        insert job;
        insert new Job_Skill__c(Job__c = job.Id, Skill__c = getSkillId('Apex'), Importance__c = 'Must Have');
        insert new Job_Skill__c(Job__c = job.Id, Skill__c = getSkillId('LWC'), Importance__c = 'Must Have');
        Job_Applicant__c applicant = apply(job, 1, new List<String>{ 'Apex' });

        Test.startTest();
        ScoringService.scoreApplicants(new Set<Id>{ job.Id });
        Test.stopTest();

        Assert.areEqual(50, getScore(applicant.Id));
    }

    @IsTest
    static void jobWithoutCriteriaScoresZero() {
        Job__c job = new Job__c(Name = 'Empty Job');
        insert job;
        Job_Applicant__c applicant = apply(job, 10, new List<String>{ 'Apex' });

        Test.startTest();
        ScoringService.scoreApplicants(new Set<Id>{ job.Id });
        Test.stopTest();

        Assert.areEqual(0, getScore(applicant.Id));
    }

    @IsTest
    static void alreadyScoredApplicantIsSkipped() {
        Job_Applicant__c applicant = apply(getJob('Salesforce Developer'), 8, new List<String>{ 'Apex' });
        applicant.Score__c = 77;
        update applicant;

        Test.startTest();
        List<ScoringService.Breakdown> breakdowns = ScoringService.scoreApplicants(new Set<Id>{ applicant.Job__c });
        Test.stopTest();

        Assert.areEqual(0, breakdowns.size());
        Assert.areEqual(77, getScore(applicant.Id));
    }

    @IsTest
    static void invocableScoresBulkApplicantsPerJob() {
        Job__c job = getJob('Salesforce Developer');
        Job__c otherJob = new Job__c(Name = 'Other Job');
        insert otherJob;

        List<Candidate__c> candidates = new List<Candidate__c>();
        for (Integer i = 0; i < 200; i++) {
            candidates.add(new Candidate__c(Name = 'Candidate ' + i, Email__c = 'candidate' + i + '@test.cvreview', Years_Experience__c = 5));
        }
        insert candidates;
        List<Job_Applicant__c> applicants = new List<Job_Applicant__c>();
        for (Candidate__c candidate : candidates) {
            applicants.add(new Job_Applicant__c(Candidate__c = candidate.Id, Job__c = job.Id));
        }
        applicants.add(new Job_Applicant__c(Candidate__c = candidates[0].Id, Job__c = otherJob.Id));
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
        Assert.areEqual(200, [SELECT COUNT() FROM Job_Applicant__c WHERE Job__c = :job.Id AND Score__c = 20]);
    }

    @IsTest
    static void recruiterWithPermissionSetCanScore() {
        User recruiter = createRecruiter();
        Job_Applicant__c applicant = apply(getJob('Salesforce Developer'), 8, new List<String>{ 'Apex', 'LWC' });

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
        User noAccess = createUser();
        Job_Applicant__c applicant = apply(getJob('Salesforce Developer'), 8, new List<String>{ 'Apex' });

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

    private static Job_Applicant__c apply(Job__c job, Decimal years, List<String> skillNames) {
        Candidate__c candidate = new Candidate__c(Name = 'Test Candidate', Email__c = 'candidate@test.cvreview', Years_Experience__c = years);
        insert candidate;
        List<Candidate_Skill__c> candidateSkills = new List<Candidate_Skill__c>();
        for (String name : skillNames) {
            candidateSkills.add(new Candidate_Skill__c(Candidate__c = candidate.Id, Skill__c = getSkillId(name)));
        }
        insert candidateSkills;
        Job_Applicant__c applicant = new Job_Applicant__c(Candidate__c = candidate.Id, Job__c = job.Id);
        insert applicant;
        return applicant;
    }

    private static Job__c getJob(String name) {
        return [SELECT Id FROM Job__c WHERE Name = :name LIMIT 1];
    }

    private static Id getSkillId(String name) {
        return [SELECT Id FROM Skill__c WHERE Name = :name LIMIT 1].Id;
    }

    private static Decimal getScore(Id applicantId) {
        return [SELECT Score__c FROM Job_Applicant__c WHERE Id = :applicantId].Score__c;
    }

    private static User createUser() {
        Profile standardUser = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniqueName = 'scoring' + Crypto.getRandomInteger() + '@test.cvreview';
        User user = new User(
            Alias = 'scorer',
            Email = uniqueName,
            Username = uniqueName,
            LastName = 'Recruiter',
            ProfileId = standardUser.Id,
            TimeZoneSidKey = 'Europe/Paris',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        // Setup objects in their own context to avoid mixed DML with the test records.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert user;
        }
        return user;
    }

    private static User createRecruiter() {
        User recruiter = createUser();
        PermissionSet permissionSet = [SELECT Id FROM PermissionSet WHERE Name = 'Clouding_HR' LIMIT 1];
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new PermissionSetAssignment(AssigneeId = recruiter.Id, PermissionSetId = permissionSet.Id);
        }
        return recruiter;
    }
}
