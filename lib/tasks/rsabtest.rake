# encoding: utf-8
REPORT_FILE_PATH = "reports/rsab.xlsx"
PERMANENCY_THRESHOLD = 30

namespace :rsabtest do

  #Usage
  #Development:   bundle exec rake rsabtest:generateReport[true]
  task :generateReport, [:check] => :environment do |t,args|
    args.with_defaults(:check => "true")
    require "#{Rails.root}/lib/task_utils"
    require 'descriptive_statistics/safe'
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

            # Approach A: consider only one related entry (the one with max time spent)
            selectedRelatedEntries = relatedEntries
            if relatedEntries.length > 1
              #Select entry with max time
              maxTime = -1
              sre = nil
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
              selectedRelatedEntries = [sre]
            end

            # Approach B: consider all entries
            # selectedRelatedEntries = relatedEntries

            selectedRelatedEntries.each do |sre|
              #Count recommendation acceptance
              acceptedRecommendations[d["rsEngine"]] = acceptedRecommendations[d["rsEngine"]] + 1
              
              #Time spent by the user on the recommended LO
              sre_d = JSON(sre["data"])
              sre_duration = sre_d["duration"].to_i
              acceptedRecommendationsTime[d["rsEngine"]].push(sre_duration)

              #Quality of the recommended LO
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
      acceptedRecommendationsTime[r].push(0) if acceptedRecommendationsTime[r].blank?
      acceptedRecommendationsQuality[r].push(0) if acceptedRecommendationsQuality[r].blank?

      puts r
      puts("Generated recommendations: '" + generatedRecommendations[r].to_s + "'")
      puts("Accepted recommendations: '" + acceptedRecommendations[r].to_s + "'")
      puts("Acceptance rate: '" + (acceptedRecommendations[r]/generatedRecommendations[r].to_f*100).round(1).to_s + "%'")
      puts("Permanency rate: '" + (acceptedRecommendationsTime[r].select{|t| t>=PERMANENCY_THRESHOLD}.length/acceptedRecommendationsTime[r].length.to_f*100).round(1).to_s + "%'")
      puts("Average time of recommendations: '" + acceptedRecommendationsTime[r].mean.round(2).to_s + "'")
      puts("Standard deviation of time of recommendations: '" + acceptedRecommendationsTime[r].standard_deviation.round(2).to_s + "'")
      puts("Average quality of recommendations: '" + acceptedRecommendationsQuality[r].mean.round(2).to_s + "'")
      puts("Standard deviation of quality of recommendations: '" + acceptedRecommendationsQuality[r].standard_deviation.round(2).to_s + "'")
      puts("")
    end

    Axlsx::Package.new do |p|
      p.workbook.add_worksheet(:name => "RS AB Test Report") do |sheet|
        rows = []
        rows << ["RS AB Test Report"]
        rows << ["RS Engine","Generated recommendations","Accepted recommendations","Acceptance rate","Permanency Rate","Time of recommendations","","Quality of recommendations",""]
        rows << ["","","","","M","SD","M","SD"]
        rowIndex = rows.length
        
        rows += Array.new(rsEngines.length).map{|r|[]}
        rsEngines.each_with_index do |n,i|
          r = rsEngines[i]
          rows[rowIndex+i] = [r,generatedRecommendations[r],acceptedRecommendations[r],(acceptedRecommendations[r]/generatedRecommendations[r].to_f*100).round(1),(acceptedRecommendationsTime[r].select{|t| t>=PERMANENCY_THRESHOLD}.length/acceptedRecommendationsTime[r].length.to_f*100).round(1),acceptedRecommendationsTime[r].mean.round(2),acceptedRecommendationsTime[r].standard_deviation.round(2),acceptedRecommendationsQuality[r].mean.round(2),acceptedRecommendationsQuality[r].standard_deviation.round(2)]
        end

        rsEngines.each_with_index do |n,i|
          r = rsEngines[i]
          rows << []
          rows << [r]
          rows << ["Time","Q"]
          puts "Invalid data!" if acceptedRecommendationsTime[r].length != acceptedRecommendationsQuality[r].length
          
          rowIndex = rows.length
          rows += Array.new(acceptedRecommendationsTime[r].length).map{|r|[]}
          acceptedRecommendationsTime[r].each_with_index do |n,i|
            rows[rowIndex+i] = [acceptedRecommendationsTime[r][i],acceptedRecommendationsQuality[r][i]]
          end
        end

        rows.each do |row|
          sheet.add_row row
        end
      end

      p.serialize(REPORT_FILE_PATH)
    end

    puts("Task Finished. Results generated at " + REPORT_FILE_PATH)
  end

  task :checkEntries => :environment do |t,args|
    printTitle("Checking Tracking System Entries")
    Rake::Task["rsabtest:removeInvalidEntries"].invoke
    Rake::Task["trsystem:populateRelatedExcursions"].invoke
    Rake::Task["trsystem:checkEntriesOfExcursions"].invoke
    Rake::Task["trsystem:deleteEntriesOfRemovedExcursions"].invoke
    printTitle("Task finished [checkEntries]")
  end

  #Remove invalid tracking system entries for ab test. Do not use in production.
  #Usage
  #Development:   bundle exec rake rsabtest:removeInvalidEntries
  task :removeInvalidEntries => :environment do |t,args|
    printTitle("Removing invalid tracking system entries for ab test")

    entriesDestroyed = 0

    ActiveRecord::Base.uncached do
      TrackingSystemEntry.find_each batch_size: 1000 do |e|
        if TrackingSystemEntry.isUserAgentBot?(e.user_agent) or !TrackingSystemEntry.isUserAgentDesktop?(e.user_agent)
          e.delete
          entriesDestroyed += 1
        end
      end
    end

    printTitle(entriesDestroyed.to_s + " entries destroyed")
    printTitle("Task finished [removeInvalidEntries]")
  end

end