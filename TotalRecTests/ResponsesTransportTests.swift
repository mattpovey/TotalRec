import XCTest
@testable import TotalRec

final class ResponsesTransportTests: XCTestCase {
    func testStreamParserEmitsOrderedSemanticEvents() throws {
        var parser = ResponsesTransport.StreamParser()
        let lines = [
            "event: response.created",
            "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}",
            "",
            "event: response.output_text.delta",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}",
            "",
            "event: response.output_text.delta",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\" world\"}",
            "",
            "event: response.completed",
            "data: {\"type\":\"response.completed\",\"response\":{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello world\"}]}]}}",
            ""
        ]

        var events: [ResponsesTransport.StreamParser.ParsedEvent] = []
        for line in lines {
            events.append(contentsOf: try parser.push(line: line))
        }
        events.append(contentsOf: try parser.finish())

        XCTAssertEqual(
            events,
            [
                .started,
                .textDelta("Hello"),
                .textDelta(" world"),
                .completed("Hello world")
            ]
        )
    }

    func testStreamParserHandlesRicherOfficialStreamingShapes() throws {
        var parser = ResponsesTransport.StreamParser()
        let lines = [
            "event: response.created",
            "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"status\":\"in_progress\",\"output\":[]}}",
            "",
            "event: response.in_progress",
            "data: {\"type\":\"response.in_progress\",\"response\":{\"id\":\"resp_1\",\"status\":\"in_progress\",\"output\":[]}}",
            "",
            "event: response.output_item.added",
            "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\",\"status\":\"in_progress\",\"role\":\"assistant\",\"content\":[]}}",
            "",
            "event: response.content_part.added",
            "data: {\"type\":\"response.content_part.added\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"\",\"annotations\":[]}}",
            "",
            "event: response.output_text.delta",
            "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hello\"}",
            "",
            "event: response.output_text.done",
            "data: {\"type\":\"response.output_text.done\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"text\":\"Hello world\"}",
            "",
            "event: response.output_item.done",
            "data: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\",\"status\":\"completed\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello world\",\"annotations\":[]}]}}",
            "",
            "event: response.completed",
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"summary\":[]},{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello world\",\"annotations\":[]}]}]}}",
            ""
        ]

        var events: [ResponsesTransport.StreamParser.ParsedEvent] = []
        for line in lines {
            events.append(contentsOf: try parser.push(line: line))
        }
        events.append(contentsOf: try parser.finish())

        XCTAssertEqual(
            events,
            [
                .started,
                .started,
                .textDelta("Hello"),
                .completed("Hello world"),
                .completed("Hello world")
            ]
        )
    }

    func testStreamParserFlushesWhenNextEventStartsWithoutBlankSeparator() throws {
        var parser = ResponsesTransport.StreamParser()
        let lines = [
            "event: response.created",
            "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"status\":\"in_progress\",\"output\":[]}}",
            "event: response.in_progress",
            "data: {\"type\":\"response.in_progress\",\"response\":{\"id\":\"resp_1\",\"status\":\"in_progress\",\"output\":[]}}",
            "event: response.output_text.delta",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}",
            "event: response.completed",
            "data: {\"type\":\"response.completed\",\"response\":{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]}]}}",
            ""
        ]

        var events: [ResponsesTransport.StreamParser.ParsedEvent] = []
        for line in lines {
            events.append(contentsOf: try parser.push(line: line))
        }
        events.append(contentsOf: try parser.finish())

        XCTAssertEqual(
            events,
            [
                .started,
                .started,
                .textDelta("Hello"),
                .completed("Hello")
            ]
        )
    }

    func testStreamParserEmitsFailedEventForErrorPayload() throws {
        var parser = ResponsesTransport.StreamParser()
        let lines = [
            "event: error",
            "data: {\"type\":\"error\",\"error\":{\"message\":\"Rate limited\"}}",
            ""
        ]

        var events: [ResponsesTransport.StreamParser.ParsedEvent] = []
        for line in lines {
            events.append(contentsOf: try parser.push(line: line))
        }

        XCTAssertEqual(events, [.failed("Rate limited")])
    }

    func testStreamParserEmitsFailedEventForResponseFailedPayload() throws {
        var parser = ResponsesTransport.StreamParser()
        let lines = [
            "event: response.failed",
            "data: {\"type\":\"response.failed\",\"response\":{\"id\":\"resp_1\",\"status\":\"failed\",\"error\":{\"message\":\"Invalid request\"}}}",
            ""
        ]

        var events: [ResponsesTransport.StreamParser.ParsedEvent] = []
        for line in lines {
            events.append(contentsOf: try parser.push(line: line))
        }

        XCTAssertEqual(events, [.failed("Invalid request")])
    }
}

final class ConversationTransportTests: XCTestCase {
    func testStreamParserFlushesOnBackToBackDataOnlyChunks() throws {
        var parser = ConversationTransport.StreamParser()
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"channel\":\"analysis\",\"reasoning\":\"We need to summarize carefully.\"},\"finish_reason\":null,\"index\":0,\"logprobs\":null}],\"created\":1775380183,\"id\":\"chunk_1\",\"model\":\"gpt-oss-120b\",\"object\":\"chat.completion.chunk\",\"system_fingerprint\":\"fastcoe\"}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"# Episode Summary\\n\",\"role\":\"assistant\"},\"finish_reason\":null,\"index\":0,\"logprobs\":null}],\"created\":1775380183,\"id\":\"chunk_1\",\"model\":\"gpt-oss-120b\",\"object\":\"chat.completion.chunk\",\"system_fingerprint\":\"fastcoe\"}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hello world\"},\"finish_reason\":null,\"index\":0,\"logprobs\":null}],\"created\":1775380183,\"id\":\"chunk_1\",\"model\":\"gpt-oss-120b\",\"object\":\"chat.completion.chunk\",\"system_fingerprint\":\"fastcoe\"}",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\",\"index\":0,\"logprobs\":null}],\"created\":1775380183,\"id\":\"chunk_1\",\"model\":\"gpt-oss-120b\",\"object\":\"chat.completion.chunk\",\"system_fingerprint\":\"fastcoe\"}"
        ]

        var events: [ConversationTransport.StreamParser.ParsedEvent] = []
        for line in lines {
            events.append(contentsOf: try parser.push(line: line))
        }
        events.append(contentsOf: try parser.finish())

        XCTAssertEqual(
            events,
            [
                .started,
                .textDelta("# Episode Summary\n"),
                .textDelta("Hello world"),
                .completed
            ]
        )
    }
}
