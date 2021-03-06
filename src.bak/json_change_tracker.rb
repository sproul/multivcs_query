require_relative 'u'
require_relative 'cspec_span_report_item'
require_relative 'change_tracker'
require 'json'
require 'socket'

class User_error < Exception
        attr_accessor :emsg
        def initialize(s)
                self.emsg = s
        end
end

class Json_change_tracker
        attr_accessor :op
        attr_accessor :error

        def initialize()
                if !Json_change_tracker.initialized
                        raise "Json_change_tracker.init must be called before Json_change_tracker objects are allocated"
                end
        end
        def error_msg(emsg)
                "<h3>Error: <font color=red>#{emsg}</font></h3>"
        end
        def exception()
                self.error
        end
        def get(h, key)
                if !h.has_key?(key)
                        self.error = User_error.new("did not find anything for key '#{key}'")
                        raise self
                end
                h[key]
        end
        def usage(emsg)
                z = start_html_page()
                z << error_msg(emsg)
                z << "To manually interact with the change tracker, visit the <a href=/ui.htm>change tracker UI</a>.<br>"
                z << Json_change_tracker.examples(self.op)
                z
        end
        def start_html_page()
                %Q[<html xmlns="http://www.w3.org/1999/xhtml" lang="en"><!doctype html>
                <head>
                <meta http-equiv="Content-type" content="text/html;charset=UTF-8">
                <title>Change tracker</title>
                </head>
                <body bgcolor=\"#CCCCCC\"><font face=arial>]
        end
        def end_html_page()
                "</font></body></html>"
        end
        def system_error(emsg, backtrace=nil)
                # nicer formatting could be implemented here to make the error more presentable in the browser:
                z = start_html_page
                z << "<h4>Error encountered: " << error_msg(emsg)
                if backtrace
                        z << "#{backtrace.join("\n")}\n"
                end
                z << "<p>See the <a href=doc.htm                target='_blank'>Change Tracker doc</a> for information and examples of valid inputs."
                z << "<p>See the <a href=samples/index.html     target='_blank'>Change Tracker sample page</a> for information and examples of CT client code."
                z
        end
        def go(op, cspec_set1, cspec_set2, output_style, pretty=false)
                if !op
                        return 400, usage("op is a required argument")
                end
                if !cspec_set1
                        return 400, usage("cspec_set1 is a required argument")
                end
                if !cspec_set2
                        return 400, usage("cspec_set2 is a required argument")
                end
                Cspec_span_report_item_set.output_style = output_style
                Cspec_span_report_item_set.pretty = pretty
                http_response_code = 200
                self.op = op

                begin
                        cc1 = Cspec_set.from_s(cspec_set1, 'cspec_set1')
                        cc2 = Cspec_set.from_s(cspec_set2, 'cspec_set2')
                rescue Error_record => e_obj
                        return e_obj.http_response_code, system_error(e_obj.emsg)
                rescue RuntimeError => re
                        return 400, system_error(re.to_s + "\n" + re.backtrace.join("\n"))
                end
                begin
                        case self.op
                        when "list_bug_IDs_between"
                                x = cc2.list_bug_IDs_since(cc1)
                        when "list_changes_between"
                                x = cc2.list_changes_since(cc1)
                        when "list_files_changed_between"
                                x = cc2.list_files_changed_since(cc1)
                        when "list_component_cspec_pairs"
                                x = cc2.list_component_cspec_pairs(cc1)
                        else
                                return 400, usage("did not know how to interpret op '#{op}'")
                        end
                rescue Error_record => e_obj
                        return e_obj.http_response_code, system_error(e_obj.emsg)
                rescue RuntimeError => e_obj
                        # https://en.wikipedia.org/wiki/List_of_HTTP_status_codes
                        # 500 server error
                        # 501 not impl
                        return 500, system_error(e_obj.to_s, e_obj.backtrace)
                rescue User_error => e_obj
                        return 400, usage(e_obj.emsg)
                end
                json_output = x.to_json()
                puts json_output unless U.test_mode
                return http_response_code, json_output
        end
        def prettify_json(json)
                json_obj = JSON.parse(json)
                JSON.pretty_generate(json_obj)
        end
        class << self
                attr_accessor :initialized
                attr_accessor :examples_by_op
                attr_accessor :usage_full_examples
                attr_accessor :web_root
                def init(web_root=nil)
                        if !Json_change_tracker.web_root
                                if web_root
                                        Json_change_tracker.web_root = web_root
                                else
                                        # at one point I had URLs w/ @WEB_ROOT@ as the protocol/server/port, so the tests would assume a running
                                        # server locally, but I decided to stop this and run connected tests on slcipcm, and mocked everywhere else.
                                        # So the URLs refer to slcipcm, and that keeps things simple.
                                        #Json_change_tracker.web_root = "http://#{Socket.gethostname}:4567"
                                        Json_change_tracker.web_root = "http://slcipcm:4567"
                                end
                        end
                        if !Json_change_tracker.examples_by_op
                                Json_change_tracker.examples_by_op = Hash.new
                                Json_change_tracker.examples_by_op["list_bug_IDs_between"] = init_example_for_op("list_bug_IDs_between", "http://slcipcm:4567/?pretty=true&op=list_bug_IDs_between&cspec_set1=%7B%22cspec%22%3A%22git%3Bgit.osn.oraclecorp.com%3Bosn/serverintegration%3B%3B%3B6b5ed0226109d443732540fee698d5d794618b64%22%2C%22cspec_deps%22%3A%5B%22git%3Bgit.osn.oraclecorp.com%3Bccs/caas%3Bmaster%3Ba1466659536cf2225eadf56f43972a25e9ee1bed%22%2C%22git%3Bgit.osn.oraclecorp.com%3Bosn/cef%3Bmaster%3B749581bac1d93cda036d33fbbdbe95f7bd0987bf%22%5D%7D&cspec_set2=%7B%22cspec_deps%22%3A%5B%22git%3Bgit.osn.oraclecorp.com%3Bccs/caas%3Bmaster%3Ba1466659536cf2225eadf56f43972a25e9ee1bed%22%2C%22git%3Bgit.osn.oraclecorp.com%3Bosn/cef%3Bmaster%3B749581bac1d93cda036d33fbbdbe95f7bd0987bf%22%5D%2C%22cspec%22%3A%22git%3Bgit.osn.oraclecorp.com%3Bosn/serverintegration%3B%3B%3B06c85af5cfa00b0e8244d723517f8c3777d7b77e%22%7D", %Q[{ "cspec": "git;git.osn.oraclecorp.com;osn/serverintegration;;6b5ed0226109d443732540fee698d5d794618b64", "cspec_deps": [ "git;git.osn.oraclecorp.com;ccs/caas;master;a1466659536cf2225eadf56f43972a25e9ee1bed", "git;git.osn.oraclecorp.com;osn/cef;master;749581bac1d93cda036d33fbbdbe95f7bd0987bf"] }], %Q[{ "cspec_deps": [ "git;git.osn.oraclecorp.com;ccs/caas;master;a1466659536cf2225eadf56f43972a25e9ee1bed", "git;git.osn.oraclecorp.com;osn/cef;master;749581bac1d93cda036d33fbbdbe95f7bd0987bf"], "cspec": "git;git.osn.oraclecorp.com;osn/serverintegration;;06c85af5cfa00b0e8244d723517f8c3777d7b77e"}])

                                Json_change_tracker.examples_by_op["list_changes_between"] = init_example_for_op("list_changes_between", "http://slcipcm:4567/?pretty=true&op=list_changes_between&cspec_set1=%7B%22cspec%22%3A%22git%3Bgit.osn.oraclecorp.com%3Bosn/serverintegration%3B%3B%3B6b5ed0226109d443732540fee698d5d794618b64%22%2C%22cspec_deps%22%3A%5B%22git%3Bgit.osn.oraclecorp.com%3Bccs/caas%3Bmaster%3Ba1466659536cf2225eadf56f43972a25e9ee1bed%22%2C%22git%3Bgit.osn.oraclecorp.com%3Bosn/cef%3Bmaster%3B749581bac1d93cda036d33fbbdbe95f7bd0987bf%22%5D%7D&cspec_set2=%7B%22cspec_deps%22%3A%5B%22git%3Bgit.osn.oraclecorp.com%3Bccs/caas%3Bmaster%3Ba1466659536cf2225eadf56f43972a25e9ee1bed%22%2C%22git%3Bgit.osn.oraclecorp.com%3Bosn/cef%3Bmaster%3B749581bac1d93cda036d33fbbdbe95f7bd0987bf%22%5D%2C%22cspec%22%3A%22git%3Bgit.osn.oraclecorp.com%3Bosn/serverintegration%3B%3B%3B06c85af5cfa00b0e8244d723517f8c3777d7b77e%22%7D", %Q[{ "cspec": "git;git.osn.oraclecorp.com;osn/serverintegration;;6b5ed0226109d443732540fee698d5d794618b64", "cspec_deps": [ "git;git.osn.oraclecorp.com;ccs/caas;master;a1466659536cf2225eadf56f43972a25e9ee1bed", "git;git.osn.oraclecorp.com;osn/cef;master;749581bac1d93cda036d33fbbdbe95f7bd0987bf"] }], %Q[{ "cspec_deps": [ "git;git.osn.oraclecorp.com;ccs/caas;master;a1466659536cf2225eadf56f43972a25e9ee1bed", "git;git.osn.oraclecorp.com;osn/cef;master;749581bac1d93cda036d33fbbdbe95f7bd0987bf"], "cspec": "git;git.osn.oraclecorp.com;osn/serverintegration;;06c85af5cfa00b0e8244d723517f8c3777d7b77e"}])

                                Json_change_tracker.examples_by_op["list_files_changed_between"] = init_example_for_op("list_files_changed_between", "http://slcipcm:4567/?pretty=true&op=list_files_changed_between&cspec_set1=%7B%22cspec%22%3A%22git%3Bgit.osn.oraclecorp.com%3Bosn/serverintegration%3B%3B%3B6b5ed0226109d443732540fee698d5d794618b64%22%2C%22cspec_deps%22%3A%5B%22git%3Bgit.osn.oraclecorp.com%3Bccs/caas%3Bmaster%3Ba1466659536cf2225eadf56f43972a25e9ee1bed%22%2C%22git%3Bgit.osn.oraclecorp.com%3Bosn/cef%3Bmaster%3B749581bac1d93cda036d33fbbdbe95f7bd0987bf%22%5D%7D&cspec_set2=%7B%22cspec_deps%22%3A%5B%22git%3Bgit.osn.oraclecorp.com%3Bccs/caas%3Bmaster%3Ba1466659536cf2225eadf56f43972a25e9ee1bed%22%2C%22git%3Bgit.osn.oraclecorp.com%3Bosn/cef%3Bmaster%3B749581bac1d93cda036d33fbbdbe95f7bd0987bf%22%5D%2C%22cspec%22%3A%22git%3Bgit.osn.oraclecorp.com%3Bosn/serverintegration%3B%3B%3B06c85af5cfa00b0e8244d723517f8c3777d7b77e%22%7D", %Q[{ "cspec": "git;git.osn.oraclecorp.com;osn/serverintegration;;6b5ed0226109d443732540fee698d5d794618b64", "cspec_deps": [ "git;git.osn.oraclecorp.com;ccs/caas;master;a1466659536cf2225eadf56f43972a25e9ee1bed", "git;git.osn.oraclecorp.com;osn/cef;master;749581bac1d93cda036d33fbbdbe95f7bd0987bf"] }], %Q[{ "cspec_deps": [ "git;git.osn.oraclecorp.com;ccs/caas;master;a1466659536cf2225eadf56f43972a25e9ee1bed", "git;git.osn.oraclecorp.com;osn/cef;master;749581bac1d93cda036d33fbbdbe95f7bd0987bf"], "cspec": "git;git.osn.oraclecorp.com;osn/serverintegration;;06c85af5cfa00b0e8244d723517f8c3777d7b77e"}])

                                z = ""
                                Json_change_tracker.examples_by_op.values.each do | example |
                                        z << example
                                end
                                Json_change_tracker.usage_full_examples = z
                                STDOUT.sync     # always flush immediately
                                STDERR.sync     # always flush immediately
                        end
                        Json_change_tracker.initialized = true
                end
                def sub_for_vars(s)
                        if !Json_change_tracker.web_root
                                raise "Json_change_tracker.web_root is null: Json_change_tracker.init never called?"
                        end
                        s.gsub('@WEB_ROOT@', Json_change_tracker.web_root)
                end
                def init_example_for_op(op, url_example, cspec_set1_example, cspec_set2_example)
                        url_example = Json_change_tracker.sub_for_vars(url_example)

                        cspec_set1_obj = JSON.parse(cspec_set1_example)
                        pretty_printed_cspec_set1_example = JSON.pretty_generate(cspec_set1_obj)

                        cspec_set2_obj = JSON.parse(cspec_set2_example)
                        pretty_printed_cspec_set2_example = JSON.pretty_generate(cspec_set2_obj)

                        z = "<h4>#{op} operation:</h4>"
                        z << "<h5>Example URL:</h5><a href='#{url_example}'>#{url_example}</a>\n"
                        z << "<h5>Example JSON describing the <b>starting</b> point set of commit IDs:</h5><pre>#{pretty_printed_cspec_set1_example}\n</pre>\n"
                        z << "<h5>Example JSON describing the <b>ending</b> point set of commit IDs:</h5><pre>#{pretty_printed_cspec_set2_example}\n</pre>\n"
                        z
                end
                def examples(example_op=nil)
                        z = "\n<h3>Example usage:</h3>\n"
                        if !example_op || !Json_change_tracker.examples_by_op.has_key?(example_op)
                                z << Json_change_tracker.usage_full_examples
                        else
                                z << Json_change_tracker.examples_by_op[example_op]
                        end
                        z
                end
                def assert_result_from_s(output_style, op, cspec_set1, cspec_set2, title)
                        http_response_code, actual_result = Json_change_tracker.new.go(op, cspec_set1, cspec_set2, output_style)
                        U.assert_eq(200, http_response_code, "#{title} HTTP response code to #{op}/#{output_style}")
                        U.assert_json_eq_f(actual_result, "#{title} for #{op}/#{output_style}")
                end
                def assert_error_result_from_s(expected_portion, op, json_input1, json_input2, expected_http_response_code, title)
                        actual_http_response_code, actual_result = Json_change_tracker.new.go(op, json_input1, json_input2, Cspec_span_report_item::OUTPUT_STYLE_TERSE)
                        U.assert_eq(expected_http_response_code, actual_http_response_code, "#{title} HTTP response code")
                        if !actual_result.include?(expected_portion)
                                U.assert_eq("[portion in...] #{expected_portion}", actual_result, title)
                        end
                end
                def test_bad_json()
                        cspec1 = "git;git.osn.oraclecorp.com;osn/serverintegration;;6b5ed0226109d443732540fee698d5d794618b64"
                        cspec2 = "git;git.osn.oraclecorp.com;osn/serverintegration;;06c85af5cfa00b0e8244d723517f8c3777d7b77e"

                        z1 = %Q[{ "cspec" : "#{cspec1}" }]
                        z2 = %Q[{ "cspec" : "#{cspec2}" }]

                        assert_error_result_from_s("did not know how to interpret op 'some_nonexistent_op'", "some_nonexistent_op", z1, z2, 400, "nonexistent op")
                        assert_error_result_from_s("cspec_set1 is a required argument", "list_bug_IDs_between", nil, z2, 400, "ridiculous null request")
                        assert_error_result_from_s(%Q[expecting JSON, but I see no hash], "list_bug_IDs_between", "", z2, 400, "empty cspec1")
                        assert_error_result_from_s(%Q[cspec_set2 is a required argument], "list_bug_IDs_between", z1, nil, 400, "nil cspec2")
                end
                def assert_close_neighbors_result(output_style, op)
                        cspec1 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;6b5ed0226109d443732540fee698d5d794618b64+"
                        cspec2 = "git;git.osn.oraclecorp.com;osn/cec-server-integration;;06c85af5cfa00b0e8244d723517f8c3777d7b77e+"

                        z1 = %Q[{ "cspec" : "#{cspec1}" }]
                        z2 = %Q[{ "cspec" : "#{cspec2}" }]
                        assert_result_from_s(output_style, op, z1, z2, "close neighbors list changes")
                end
                def test_close_neighbors_all_ops()
                        test_close_neighbors_all_ops_for_output_style(Cspec_span_report_item::OUTPUT_STYLE_TERSE)
                        test_close_neighbors_all_ops_for_output_style(Cspec_span_report_item::OUTPUT_STYLE_NORMAL)
                        test_close_neighbors_all_ops_for_output_style(Cspec_span_report_item::OUTPUT_STYLE_EXPANDED)
                end 
                def test_close_neighbors_all_ops_for_output_style(output_style)
                        assert_close_neighbors_result(output_style, "list_changes_between")
                        assert_close_neighbors_result(output_style, "list_bug_IDs_between")
                        assert_close_neighbors_result(output_style, "list_files_changed_between")
                end
                def assert_close_neighbors_cspec_by_http(vn, op)
                        z1 = "#{Json_change_tracker.web_root}/test_cspec_set1_v#{vn}.json"
                        z2 = "#{Json_change_tracker.web_root}/test_cspec_set2_v#{vn}.json"
                        assert_result_from_s(Cspec_span_report_item::OUTPUT_STYLE_TERSE, op, z1, z2, "close neighbors list changes by http, v#{vn}")
                end
                def test_cspec_by_http_for_all_ops_v1()
                        assert_close_neighbors_cspec_by_http(1, "list_changes_between")
                        assert_close_neighbors_cspec_by_http(1, "list_bug_IDs_between")
                        assert_close_neighbors_cspec_by_http(1, "list_files_changed_between")
                end
                def test_cspec_by_http_for_all_ops_v2()
                        assert_close_neighbors_cspec_by_http(2, "list_changes_between")
                        assert_close_neighbors_cspec_by_http(2, "list_bug_IDs_between")
                        assert_close_neighbors_cspec_by_http(2, "list_files_changed_between")
                end
                def test_nonexistent_codeline()
                        cspec1 = "git;git.osn.oraclecorp.com;osn/serverintegrationXXXXX;;6b5ed0226109d443732540fee698d5d794618b64"
                        cspec2 = "git;git.osn.oraclecorp.com;osn/serverintegrationXXXXX;;06c85af5cfa00b0e8244d723517f8c3777d7b77e"

                        z1 = %Q[{ "cspec" : "#{cspec1}" }]
                        z2 = %Q[{ "cspec" : "#{cspec2}" }]
                        assert_error_result_from_s(%Q[GitLab: The project you were looking for could not be found.], "list_changes_between", z1, z2, 500, "nonexistent codeline")
                end
                def test_note_renamed_repo()
                        Global.init_data
                        from = "git;test.nonexistent.com;osn/from_abc"
                        to   = "git;test.nonexistent.com;osn/to_abc"
                        renamed_repos_h = Global.data.h["renamed_repos"]
                        if renamed_repos_h
                                renamed_repos_h.delete(from)
                                U.assert(!renamed_repos_h.has_key?(from), "verify #{from} key not in renamed_repos hash #{renamed_repos_h}")
                        end
                        Repo.note_renamed_repo(from, to, true)
                        renamed_repos_h = Global.data.h["renamed_repos"]
                        U.assert_eq(to, renamed_repos_h[from], "verify #{from} key has been entered in renamed_repos hash #{renamed_repos_h}")
                        renamed_repos_h.delete(from)
                end
                def test_note_renamed_branch()
                        Global.init_data
                        from = "git;test.nonexistent.com;osn/some_project;old_branch"
                        to   = "git;test.nonexistent.com;osn/some_project;new_branch"
                        renamed_branches_h = Global.data.h["renamed_branches"]
                        if renamed_branches_h
                                renamed_branches_h.delete(from)
                                U.assert(!renamed_branches_h.has_key?(from), "verify #{from} key not in renamed_branches hash #{renamed_branches_h}")
                        end
                        Repo.note_renamed_branch(from, to, true)
                        renamed_branches_h = Global.data.h["renamed_branches"]
                        U.assert_eq(to, renamed_branches_h[from], "verify #{from} key has been entered in renamed_branches hash #{renamed_branches_h}")
                        renamed_branches_h.delete(from)
                end
                def test_steve_roth_v23()
                        z1 = %Q[http://slcipcm:4567/cec_18.3.5-1808091203_paas.json]
                        z2 = %Q[http://slcipcm:4567/cec_18.4.1-1808081448_paas.json]
                        assert_error_result_from_s("[]", "list_changes_between", z1, z2, 200, "changes in full steve roth comparison")
                        assert_error_result_from_s("[]", "list_files_changed_between", z1, z2, 200, "files changed in full steve roth comparison")
                end
                def test_steve_roth_v23_Desktop()
                        z1 = %Q[http://slcipcm:4567/cec_18.3.5-1808091203_paas_Desktop.json]
                        z2 = %Q[http://slcipcm:4567/cec_18.4.1-1808081448_paas_Desktop.json]
                        assert_error_result_from_s("[]", "list_changes_between", z1, z2, 200, "steve roth comparison w/ just Desktop")
                end
                def test()
                        Json_change_tracker.init()
                        test_steve_roth_v23
                        test_steve_roth_v23_Desktop
                        test_close_neighbors_all_ops
                        test_note_renamed_branch                        
                        test_note_renamed_repo                        
                        test_cspec_by_http_for_all_ops_v2
                        test_cspec_by_http_for_all_ops_v1
                        test_bad_json
                        test_nonexistent_codeline
                end
                def local_url(path)
                        "#{Json_change_tracker.web_root}#{path}"
                end
                def load_local(path)
                        fn = "#{U.initial_working_directory}/public/#{path}"
                        Json_change_tracker.sub_for_vars(IO.read(fn))
                end
        end
end
# current generated json from steve roth:
#     {
#      "name" : "analytics",
#      "buildnum" : "331",
#      "buildurl" : "https://osnci.us.oracle.com/job/analytics.build.pl.master/331/",
#      "version" : "1.0.331",
#      "scmtype" : "git",
#      "git_branch" : "master",
#      "git_sha" : "b7bcf7a7c2b87882745882672448f542bbd68777",
#      "git_repo" : "cef.git",
#      "cspec" : "git;git.osn.oraclecorp.com;osn/cef.git;master;b7bcf7a7c2b87882745882672448f542bbd68777"
#    },
#    {
#      "name" : "caas",
#      "buildnum" : "3308",
#      "buildurl" : "https://osnci.us.oracle.com/job/caas.build.pl.master/3308/",
#      "version" : "1.0.3308",
#      "scmtype" : "git",
#      "git_branch" : "master",
#      "git_sha" : "20f37a826a836397a35de83129af1979f9815246",
#      "git_repo" : "caas.git",
#      "cspec" : "git;git.osn.oraclecorp.com;ccs/caas.git;master;20f37a826a836397a35de83129af1979f9815246"
#    },
#    {
#      "name" : "docs-server",
#      "buildnum" : "763",
#      "buildurl" : "https://osnci.us.oracle.com/job/docs.release.pl.master/763/",
#      "version" : "1.0.1013",
#      "scmtype" : "svn",
#      "svn_branch" : "cloudtrunk-externalcompute",
#      "svn_revision" : "160529",
#      "svn_repo" : "adc4110308.us.oracle.com/svn/idc/products/cs",
#      "cspec" : "svn;adc4110308.us.oracle.com/svn/idc/products/cs;cloudtrunk-externalcompute;160529"
#    },
#    {
#      "name" : "pipeline-common",
#      "buildnum" : "15",
#      "buildurl" : "https://osnci.us.oracle.com/job/pipeline-common.build.release.pl.master/15/",
#      "version" : "1.0.15",
#      "scmtype" : "git",
#      "git_branch" : "master",
#      "git_sha" : "f28274b94ec9d32a034456f55af1d1121d200ca7",
#      "git_repo" : "pipeline-common.git",
#      "cspec" : "git;git.osn.oraclecorp.com;osn/pipeline-common.git;master;f28274b94ec9d32a034456f55af1d1121d200ca7"
#    },
#    {
#      "name" : "servercommon",
#      "buildnum" : "309",
#      "buildurl" : "https://osnci.us.oracle.com/job/servercommon.build.pl.master/309/",
#      "version" : "1.0.309",
#      "scmtype" : "git",
#      "git_branch" : "master",
#      "git_sha" : "2cda74324ba4043c2a26e642d011ddf1e6f53076",
#      "git_repo" : "servercommon.git",
#      "cspec" : "git;git.osn.oraclecorp.com;osn/servercommon.git;master;2cda74324ba4043c2a26e642d011ddf1e6f53076"
#    },
#    {
#      "name" : "waggle",
#      "buildnum" : "541",
#      "buildurl" : "https://osnci.us.oracle.com/job/social.build.pl.master/541/",
#      "version" : "1.0.541",
#      "scmtype" : "git",
#      "git_branch" : "master",
#      "git_sha" : "2448cb0c448c82fcc52333db4965a4bc9ab0829e",
#      "git_repo" : "waggle.git",
#      "cspec" : "git;git.osn.oraclecorp.com;osn/waggle.git;master;2448cb0c448c82fcc52333db4965a4bc9ab0829e"
#    }
#
#    # old one based on old.deps.gradle
#        {
#      "name" : "analytics",
#      "buildnum" : "184",
#      "buildurl" : "https://osnci.us.oracle.com/job/analytics.build.pl.master_external/184/",
#      "version" : "1.master_external.184",
#      "scmtype" : "git",
#      "git_branch" : "master_external",
#      "git_sha" : "73a08ea1ad92bfeaedb17ed2e9df8c638ce3a10c",
#      "git_repo" : "cef.git",
#      "cspec" : "git;git.osn.oraclecorp.com;osn/cef.git;master_external;73a08ea1ad92bfeaedb17ed2e9df8c638ce3a10c"
#    },
#    {
#      "name" : "caas",
#      "buildnum" : "298",
#      "buildurl" : "https://osnci.us.oracle.com/job/caas.build.pl.master_external/298/",
#      "version" : "1.master_external.298",
#      "scmtype" : "git",
#      "git_branch" : "master_external",
#      "git_sha" : "0cb54267b9c463cd2ba17e456c0783a976652ebf",
#      "git_repo" : "caas.git",
#      "cspec" : "git;git.osn.oraclecorp.com;ccs/caas.git;master_external;0cb54267b9c463cd2ba17e456c0783a976652ebf"
#    },
#    {
#      "name" : "docs-server",
#      "buildnum" : "304",
#      "buildurl" : "https://osnci.us.oracle.com/job/docs.build.pl.master_external/304/",
#      "version" : "1.master_external.304",
#      "scmtype" : "svn",
#      "svn_branch" : "cloudtrunk-externalcompute",
#      "svn_revision" : "158875",
#      "svn_repo" : "adc4110308.us.oracle.com/svn/idc/products/cs",
#      "cspec" : "svn;adc4110308.us.oracle.com/svn/idc/products/cs;cloudtrunk-externalcompute;158875"
#    },
#    {
#      "name" : "pipeline-common",
#      "buildnum" : "9",
#      "buildurl" : "https://osnci.us.oracle.com/job/pipeline-common.build.release.pl.master_external/9/",
#      "version" : "1.master_external.9",
#      "scmtype" : "git",
#      "git_branch" : "master_external",
#      "git_sha" : "673fe143be566ad9fccd05ff6c8ac1c65a597618",
#      "git_repo" : "pipeline-common.git",
#      "cspec" : "git;git.osn.oraclecorp.com;osn/pipeline-common.git;master_external;673fe143be566ad9fccd05ff6c8ac1c65a597618"
#    },
#    {
#      "name" : "servercommon",
#      "buildnum" : "243",
#      "buildurl" : "https://osnci.us.oracle.com/job/servercommon.build.pl.master_external/243/",
#      "version" : "1.master_external.243",
#      "scmtype" : "git",
#      "git_branch" : "master_external",
#      "git_sha" : "81f98f5fa34c5e86cdc7b564ac82a0b5c92dbe82",
#      "git_repo" : "servercommon.git",
#      "cspec" : "git;git.osn.oraclecorp.com;osn/servercommon.git;master_external;81f98f5fa34c5e86cdc7b564ac82a0b5c92dbe82"
#    },
#    {
#      "name" : "waggle",
#      "buildnum" : "396",
#      "buildurl" : "https://osnci.us.oracle.com/job/social.build.pl.master_external/396/",
#      "version" : "1.master_external.396",
#      "scmtype" : "git",
#      "git_branch" : "master_external",
#      "git_sha" : "a2962702d256fd8abdacb8418bc9ea23fdd235f4",
#      "git_repo" : "waggle.git",
#      "cspec" : "git;git.osn.oraclecorp.com;osn/waggle.git;master_external;a2962702d256fd8abdacb8418bc9ea23fdd235f4"
#    }
