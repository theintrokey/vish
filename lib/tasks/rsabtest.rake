# encoding: utf-8
REPORT_FILE_PATH = "reports/rsab.txt"

namespace :rsabtest do

  task :prepare do
    require "#{Rails.root}/lib/task_utils"
    prepareFile(REPORT_FILE_PATH)
    writeInFile("Recommender System AB Test Report")
  end

  def writeInFile(line)
    write(line,REPORT_FILE_PATH)
  end

  #Usage
  #Development:   bundle exec rake rsabtest:generateReport[true,false]
  task :generateReport, [:prepare, :check] => :environment do |t,args|
    args.with_defaults(:prepare => "true", :check => "true")
    require 'descriptive_statistics/safe'
    Rake::Task["rsabtest:prepare"].invoke if args.prepare == "true"
    Rake::Task["rsabtest:checkEntries"].invoke if args.check == "true"
    printTitle("Generating AB Test Report")

    startDate = DateTime.new(2019,3,1) #(year,month,day)
    endDate = DateTime.new(2019,6,30)

    rsEngines = ["cq","c","q","r"]
    generatedRecommendations = {}
    acceptedRecommendations = {}
    acceptedRecommendationsTime = {}
    acceptedRecommendationsQuality = {}
    loepData = {} #Testing: loepData = {"520" => 7.64, "580" => 1.39}
    rsEngines.each do |r|
      generatedRecommendations[r] = 0
      acceptedRecommendations[r] = 0
      acceptedRecommendationsTime[r] = ([].extend(DescriptiveStatistics))
      acceptedRecommendationsQuality[r] = ([].extend(DescriptiveStatistics))
    end

    ActiveRecord::Base.uncached do
      TrackingSystemEntry.where(:app_id=>"ViSHRecommendations", :created_at => startDate..endDate).find_each batch_size: 1000 do |e|
        begin
          d = JSON(e["data"])
          if rsEngines.include?(d["rsEngine"])
            
            #Count generated recommendation
            generatedRecommendations[d["rsEngine"]] = generatedRecommendations[d["rsEngine"]] + 1
            
            #Get tracking system entries generated by LOs visited through these recommendations
            relatedEntries = TrackingSystemEntry.where(:app_id => "ViSH Viewer", :tracking_system_entry_id => e.id, :created_at => startDate..endDate)
            
            #Check if recommendation was accepted
            nre = relatedEntries.length
            if nre > 0
              #Count acceptance
              acceptedRecommendations[d["rsEngine"]] = acceptedRecommendations[d["rsEngine"]] + 1
              
              #Get time spent by the user on the recommended LO (if several, only max time is considered)
              if nre == 1
                sre = relatedEntries.first
              else
                #Select entry with max time
                maxTime = -1
                relatedEntries.each do |re|
                  begin
                    re_d = JSON(re["data"])
                    re_duration = re_d["duration"].to_i
                    if re_duration > maxTime
                      maxTime = re_duration
                      sre = re
                    end
                  rescue Exception => e
                    puts "Exception processing VV entry: " + e.message
                  end
                end
              end

              sre_d = JSON(sre["data"])
              sre_duration = sre_d["duration"].to_i
              acceptedRecommendationsTime[d["rsEngine"]].push(sre_duration)
              
              #Quality
              loId = sre_d["lo"]["id"]
              lo = Excursion.find_by_id(loId.to_i)
              unless lo.nil?
                quality = lo.reviewers_qscore_loriam.to_f
              else
                quality = loepData[loId]
              end
              unless quality.nil?
                acceptedRecommendationsQuality[d["rsEngine"]].push(quality)
              else
                puts "No quality for LO with id: " + loId
              end
            end
            
          else
            puts "Error: unrecognized rsEngine " + d["rsEngine"]
          end
        rescue Exception => e
          puts "Exception: " + e.message
        end
      end
    end


    rsEngines.each do |r|
      writeInFile("System: '" + r + "'")
      writeInFile("Generated recommendations: '" + generatedRecommendations[r].to_s + "'")
      writeInFile("Accepted recommendations: '" + acceptedRecommendations[r].to_s + "'")
      writeInFile("Average time of recommendations: '" + acceptedRecommendationsTime[r].mean.to_s + "'")
      writeInFile("Standard deviation of time of recommendations: '" + acceptedRecommendationsTime[r].standard_deviation.to_s + "'")
      writeInFile("Average quality of recommendations: '" + acceptedRecommendationsQuality[r].mean.to_s + "'")
      writeInFile("Standard deviation of quality of recommendations: '" + acceptedRecommendationsQuality[r].standard_deviation.to_s + "'")
      writeInFile("")
    end

    printTitle("Task finished")
  end

  task :checkEntries => :environment do |t,args|
    printTitle("Checking Tracking System Entries")
    Rake::Task["trsystem:removeBotEntries"].invoke
    Rake::Task["trsystem:populateRelatedExcursions"].invoke
    Rake::Task["trsystem:checkEntriesOfExcursions"].invoke
    Rake::Task["trsystem:deleteEntriesOfRemovedExcursions"].invoke
  end

end