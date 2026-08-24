import Foundation
import Testing
@testable import BloomCore

/// The whole token stream for a sample of every language the highlighter knows, recorded once and
/// compared whole. The scanner was rewritten for speed (hoisted word sets, hoisted UTF-16 needles,
/// a `switch` in place of membership tests against array literals) and the entire point of that
/// work was that nothing observable changes, which no assertion about one construct at a time can
/// show. A failure here prints the two dumps, so the line and the token that moved are readable
/// from the diff. Re-record it only when a highlighting change is intended.
@Suite("Syntax highlighter goldens", .tags(.agentProtocol))
struct SyntaxHighlighterGoldenTests {
    @Test("tokenizes every language exactly as recorded")
    func matchesTheRecordedTokens() {
        #expect(dumpTokens() == goldenTokens)
    }
}

/// `kind:text` per token, pipe separated, one line per source line, grouped by language.
private func dumpTokens() -> String {
    var out = ""
    for language in Language.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
        guard let source = samples[language] else {
            out += "== \(language.rawValue)\nno sample\n"
            continue
        }
        out += "== \(language.rawValue)\n"
        let lines = source.components(separatedBy: "\n")
        for (index, tokens) in SyntaxHighlighter.tokenize(source: source, language: language).enumerated() {
            let units = Array(lines[index].utf16)
            let described = tokens.map {
                "\($0.kind.rawValue):\(String(decoding: units[$0.range], as: UTF16.self))"
            }
            out += "\(index)|\(described.joined(separator: "|"))\n"
        }
    }
    return out.trimmingCharacters(in: .newlines)
}

private let samples: [Language: String] = [
    .php: """
    <?php

    namespace App\\Services;

    #[Attribute]
    final class Report implements Contract
    {
        public const LIMIT = 1_000;
        private ?string $name = null;

        public function build(array $rows = [], int $depth = 0x1f): string
        {
            // a line comment
            /* a block
               comment */
            $out = <<<SQL
                select * from things where id = $id
            SQL;
            $sql = <<<'RAW'
                literal $notInterpolated
            RAW;
            return match (true) {
                $depth <= 0 => "empty {$this->name} \\n",
                default => 'plain' . self::LIMIT,
            };
        }
    }
    """,
    .blade: """
    {{-- a blade comment --}}
    <div class="card" @click="go">
        @foreach ($items as $item)
            {{ $item->name }}
            {!! $item->html !!}
        @endforeach
        <!-- html comment -->
    </div>
    """,
    .swift: """
    import Foundation

    @MainActor
    public struct Widget: Sendable {
        // one line
        /* block */
        private let count: Int = 0b1010
        var name: String { "x" }

        func run() async throws -> [String] {
            let text = \"\"\"
            multi \\(name) line
            \"\"\"
            let raw = #\"not \\(interpolated)\"#
            guard count != 0, count >= 1 else { return [] }
            return [text, "a\\u{1F600}b"]
        }
    }
    """,
    .javascript: """
    import { thing } from './thing.js';

    export default async function run(a = 1, ...rest) {
      // comment
      const re = /^a[b/c]+$/gi;
      const div = a / 2;
      const t = `hey ${a + 1} there`;
      if (a === 1 && rest?.length > 0) return null;
      return { a, b: true, c: undefined };
    }
    """,
    .typescript: """
    interface Shape<T extends object> {
      readonly kind: 'circle' | 'square';
      area(): number;
    }

    export const make = <T,>(x: T): Shape<T> => ({ kind: 'circle', area: () => 1.5e3 });
    """,
    .python: """
    from __future__ import annotations

    class Thing:
        # a comment
        def __init__(self, name: str = "x") -> None:
            self.name = name
            self.items = [1, 2, 3]

        async def run(self, *args, **kwargs):
            if self.name is None or not args:
                raise ValueError(f"bad {self.name!r}")
            return {k: v for k, v in kwargs.items()}
    """,
    .ruby: """
    module Reporting
      class Report < Base
        # a comment
        def initialize(name:, limit: 10)
          @name = name
          @limit = limit
        end

        def to_s
          "#{@name} (#{@limit})"
        end
      end
    end
    """,
    .go: """
    package main

    import "fmt"

    type Report struct {
        Name  string
        Limit int
    }

    func (r *Report) String() string {
        // comment
        if r.Limit == 0 {
            return ""
        }
        return fmt.Sprintf("%s/%d", r.Name, r.Limit)
    }
    """,
    .rust: """
    use std::collections::HashMap;

    #[derive(Debug, Clone)]
    pub struct Report<'a> {
        pub name: &'a str,
        pub limit: u32,
    }

    impl<'a> Report<'a> {
        pub fn new(name: &'a str) -> Self {
            // comment
            Self { name, limit: 0xff }
        }
    }
    """,
    .java: """
    package com.example;

    import java.util.List;

    @Override
    public final class Report {
        private static final int LIMIT = 1000;

        public String build(List<String> rows) {
            /* block */
            if (rows.isEmpty()) return "";
            return String.join(",", rows);
        }
    }
    """,
    .kotlin: """
    package com.example

    import kotlin.math.max

    data class Report(val name: String, val limit: Int = 10) {
        fun build(rows: List<String>): String {
            // comment
            if (rows.isEmpty()) return ""
            return rows.joinToString(",") { it.trim() }
        }
    }
    """,
    .css: """
    /* a comment */
    :root {
      --brand: #ff8800;
      font-size: 14px;
    }

    .card > .title:hover {
      color: var(--brand);
      margin: 0 auto !important;
    }
    """,
    .html: """
    <!doctype html>
    <html lang="en">
      <!-- a comment -->
      <head>
        <meta charset="utf-8" />
        <title>Bloom</title>
      </head>
      <body class="dark" data-x='1'>
        <p>Hello &amp; welcome</p>
      </body>
    </html>
    """,
    .json: """
    {
      "name": "bloom",
      "version": "0.3.0",
      "nested": { "a": [1, 2.5, true, false, null] },
      "escaped": "a \\"b\\" c"
    }
    """,
    .yaml: """
    # a comment
    name: bloom
    on:
      push:
        branches: [main]
    jobs:
      test:
        runs-on: macos-26
        steps:
          - uses: actions/checkout@v4
          - run: |
              make test
    """,
    .toml: """
    # a comment
    [package]
    name = "bloom"
    version = "0.3.0"

    [dependencies]
    serde = { version = "1.0", features = ["derive"] }
    """,
    .markdown: """
    # Title

    Some *emphasis* and `code` and a [link](https://example.com).

    ```swift
    let x = 1
    ```

    [//]: # (a comment)

    - one
    - two
    """,
    .shell: """
    #!/usr/bin/env bash
    set -euo pipefail

    # a comment
    NAME="${1:-bloom}"
    for file in "$@"; do
      if [[ -f "$file" ]]; then
        echo "found $file"
      else
        exit 1
      fi
    done
    """,
    .sql: """
    -- a comment
    select t.id, count(*) as total
    from things t
    inner join owners o on o.id = t.owner_id
    where t.created_at >= '2024-01-01'
      and t.name like '%bloom%'
    group by t.id
    order by total desc
    limit 10;
    """,
    .vue: """
    <template>
      <!-- comment -->
      <div class="card" :title="name" @click="go">{{ name }}</div>
    </template>

    <script setup>
    import { ref } from 'vue';
    const name = ref('bloom');
    </script>
    """,
    .xml: """
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- a comment -->
    <plist version="1.0">
      <dict>
        <key>CFBundleName</key>
        <string>Bloom</string>
      </dict>
    </plist>
    """,
    .plainText: """
    Just some words, 1234 and a "quote" plus (brackets).
    A second line -> with an arrow.
    """,
]

private let goldenTokens = #"""
== blade
0|comment:{{-- a blade comment --}}
1|operator:<|type:div|plain: |keyword:class|operator:=|string:"card"|plain: |attribute:@click|operator:=|string:"go"|operator:>
2|plain:    |attribute:@foreach|plain: |punctuation:(|variable:$items|plain: |keyword:as|plain: |variable:$item|punctuation:)
3|plain:        |operator:{{|plain: |variable:$item|operator:->|plain:name|plain: |operator:}}
4|plain:        |operator:{!!|plain: |variable:$item|operator:->|plain:html|plain: |operator:!!}
5|plain:    |attribute:@endforeach
6|plain:    |comment:<!-- html comment -->
7|operator:</|type:div|operator:>
== css
0|comment:/* a comment */
1|punctuation::|plain:root|plain: |punctuation:{
2|plain:  |operator:--|attribute:brand|punctuation::|plain: |punctuation:#|plain:ff8800|punctuation:;
3|plain:  |plain:font|operator:-|attribute:size|punctuation::|plain: |number:14|plain:px|punctuation:;
4|punctuation:}
5|
6|punctuation:.|plain:card|plain: |operator:>|plain: |punctuation:.|attribute:title|punctuation::|plain:hover|plain: |punctuation:{
7|plain:  |attribute:color|punctuation::|plain: |keyword:var|punctuation:(|operator:--|plain:brand|punctuation:);
8|plain:  |attribute:margin|punctuation::|plain: |number:0|plain: |plain:auto|plain: |operator:!|plain:important|punctuation:;
9|punctuation:}
== go
0|keyword:package|plain: |plain:main
1|
2|keyword:import|plain: |string:"fmt"
3|
4|plain:type|plain: |type:Report|plain: |keyword:struct|plain: |punctuation:{
5|plain:    |type:Name|plain:  |type:string
6|plain:    |type:Limit|plain: |type:int
7|punctuation:}
8|
9|keyword:func|plain: |punctuation:(|plain:r|plain: |operator:*|type:Report|punctuation:)|plain: |type:String|punctuation:()|plain: |type:string|plain: |punctuation:{
10|plain:    |comment:// comment
11|plain:    |keyword:if|plain: |plain:r|punctuation:.|type:Limit|plain: |operator:==|plain: |number:0|plain: |punctuation:{
12|plain:        |keyword:return|plain: |string:""
13|plain:    |punctuation:}
14|plain:    |keyword:return|plain: |plain:fmt|punctuation:.|type:Sprintf|punctuation:(|string:"%s/%d"|punctuation:,|plain: |plain:r|punctuation:.|type:Name|punctuation:,|plain: |plain:r|punctuation:.|type:Limit|punctuation:)
15|punctuation:}
== html
0|operator:<!|attribute:doctype|plain: |attribute:html|operator:>
1|operator:<|type:html|plain: |attribute:lang|operator:=|string:"en"|operator:>
2|plain:  |comment:<!-- a comment -->
3|plain:  |operator:<|type:head|operator:>
4|plain:    |operator:<|type:meta|plain: |attribute:charset|operator:=|string:"utf-8"|plain: |operator:/>
5|plain:    |operator:<|type:title|operator:>|type:Bloom|operator:</|type:title|operator:>
6|plain:  |operator:</|type:head|operator:>
7|plain:  |operator:<|type:body|plain: |keyword:class|operator:=|string:"dark"|plain: |attribute:data|operator:-|attribute:x|operator:=|string:'1'|operator:>
8|plain:    |operator:<|type:p|operator:>|type:Hello|plain: |operator:&|plain:amp|punctuation:;|plain: |plain:welcome|operator:</|type:p|operator:>
9|plain:  |operator:</|type:body|operator:>
10|operator:</|type:html|operator:>
== java
0|keyword:package|plain: |plain:com|punctuation:.|plain:example|punctuation:;
1|
2|keyword:import|plain: |plain:java|punctuation:.|plain:util|punctuation:.|type:List|punctuation:;
3|
4|attribute:@Override
5|keyword:public|plain: |keyword:final|plain: |keyword:class|plain: |type:Report|plain: |punctuation:{
6|plain:    |keyword:private|plain: |keyword:static|plain: |keyword:final|plain: |type:int|plain: |type:LIMIT|plain: |operator:=|plain: |number:1000|punctuation:;
7|
8|plain:    |keyword:public|plain: |type:String|plain: |function:build|punctuation:(|type:List|operator:<|type:String|operator:>|plain: |plain:rows|punctuation:)|plain: |punctuation:{
9|plain:        |comment:/* block */
10|plain:        |keyword:if|plain: |punctuation:(|plain:rows|punctuation:.|function:isEmpty|punctuation:())|plain: |keyword:return|plain: |string:""|punctuation:;
11|plain:        |keyword:return|plain: |type:String|punctuation:.|function:join|punctuation:(|string:","|punctuation:,|plain: |plain:rows|punctuation:);
12|plain:    |punctuation:}
13|punctuation:}
== javascript
0|keyword:import|plain: |punctuation:{|plain: |plain:thing|plain: |punctuation:}|plain: |keyword:from|plain: |string:'./thing.js'|punctuation:;
1|
2|keyword:export|plain: |keyword:default|plain: |keyword:async|plain: |keyword:function|plain: |function:run|punctuation:(|plain:a|plain: |operator:=|plain: |number:1|punctuation:,|plain: |operator:...|plain:rest|punctuation:)|plain: |punctuation:{
3|plain:  |comment:// comment
4|plain:  |keyword:const|plain: |plain:re|plain: |operator:=|plain: |regex:/^a[b/c]+$/gi|punctuation:;
5|plain:  |keyword:const|plain: |plain:div|plain: |operator:=|plain: |plain:a|plain: |operator:/|plain: |number:2|punctuation:;
6|plain:  |keyword:const|plain: |plain:t|plain: |operator:=|plain: |string:`hey |variable:${a + 1}|string: there`|punctuation:;
7|plain:  |keyword:if|plain: |punctuation:(|plain:a|plain: |operator:===|plain: |number:1|plain: |operator:&&|plain: |plain:rest|operator:?.|plain:length|plain: |operator:>|plain: |number:0|punctuation:)|plain: |keyword:return|plain: |constant:null|punctuation:;
8|plain:  |keyword:return|plain: |punctuation:{|plain: |plain:a|punctuation:,|plain: |plain:b|punctuation::|plain: |constant:true|punctuation:,|plain: |plain:c|punctuation::|plain: |constant:undefined|plain: |punctuation:};
9|punctuation:}
== json
0|punctuation:{
1|plain:  |string:"name"|punctuation::|plain: |string:"bloom"|punctuation:,
2|plain:  |string:"version"|punctuation::|plain: |string:"0.3.0"|punctuation:,
3|plain:  |string:"nested"|punctuation::|plain: |punctuation:{|plain: |string:"a"|punctuation::|plain: |punctuation:[|number:1|punctuation:,|plain: |number:2.5|punctuation:,|plain: |keyword:true|punctuation:,|plain: |keyword:false|punctuation:,|plain: |constant:null|punctuation:]|plain: |punctuation:},
4|plain:  |string:"escaped"|punctuation::|plain: |string:"a \"b\" c"
5|punctuation:}
== kotlin
0|keyword:package|plain: |plain:com|punctuation:.|plain:example
1|
2|keyword:import|plain: |plain:kotlin|punctuation:.|plain:math|punctuation:.|plain:max
3|
4|plain:data|plain: |keyword:class|plain: |type:Report|punctuation:(|plain:val|plain: |plain:name|punctuation::|plain: |type:String|punctuation:,|plain: |plain:val|plain: |plain:limit|punctuation::|plain: |type:Int|plain: |operator:=|plain: |number:10|punctuation:)|plain: |punctuation:{
5|plain:    |keyword:fun|plain: |function:build|punctuation:(|plain:rows|punctuation::|plain: |type:List|operator:<|type:String|operator:>|punctuation:):|plain: |type:String|plain: |punctuation:{
6|plain:        |comment:// comment
7|plain:        |keyword:if|plain: |punctuation:(|plain:rows|punctuation:.|function:isEmpty|punctuation:())|plain: |keyword:return|plain: |string:""
8|plain:        |keyword:return|plain: |plain:rows|punctuation:.|function:joinToString|punctuation:(|string:","|punctuation:)|plain: |punctuation:{|plain: |plain:it|punctuation:.|function:trim|punctuation:()|plain: |punctuation:}
9|plain:    |punctuation:}
10|punctuation:}
== markdown
0|punctuation:#|plain: |type:Title
1|
2|type:Some|plain: |operator:*|plain:emphasis|operator:*|plain: |plain:and|plain: |plain:`|plain:code|plain:`|plain: |plain:and|plain: |plain:a|plain: |punctuation:[|plain:link|punctuation:](|plain:https|punctuation::|operator://|plain:example|punctuation:.|plain:com|punctuation:).
3|
4|punctuation:```swift
5|keyword:let|plain: |plain:x|plain: |operator:=|plain: |number:1
6|punctuation:```
7|
8|comment:[//]: # (a comment)
9|
10|operator:-|plain: |plain:one
11|operator:-|plain: |plain:two
== php
0|punctuation:<?php
1|
2|keyword:namespace|plain: |type:App|punctuation:\|type:Services|punctuation:;
3|
4|attribute:#[|type:Attribute|punctuation:]
5|keyword:final|plain: |keyword:class|plain: |type:Report|plain: |keyword:implements|plain: |type:Contract
6|punctuation:{
7|plain:    |keyword:public|plain: |keyword:const|plain: |type:LIMIT|plain: |operator:=|plain: |number:1_000|punctuation:;
8|plain:    |keyword:private|plain: |operator:?|type:string|plain: |variable:$name|plain: |operator:=|plain: |constant:null|punctuation:;
9|
10|plain:    |keyword:public|plain: |keyword:function|plain: |function:build|punctuation:(|type:array|plain: |variable:$rows|plain: |operator:=|plain: |punctuation:[],|plain: |type:int|plain: |variable:$depth|plain: |operator:=|plain: |number:0x1f|punctuation:):|plain: |type:string
11|plain:    |punctuation:{
12|plain:        |comment:// a line comment
13|plain:        |comment:/* a block
14|comment:           comment */
15|plain:        |variable:$out|plain: |operator:=|plain: |string:<<<SQL
16|string:            select * from things where id = |variable:$id
17|string:        SQL;
18|plain:        |variable:$sql|plain: |operator:=|plain: |string:<<<'RAW'
19|string:            literal $notInterpolated
20|string:        RAW;
21|plain:        |keyword:return|plain: |keyword:match|plain: |punctuation:(|constant:true|punctuation:)|plain: |punctuation:{
22|plain:            |variable:$depth|plain: |operator:<=|plain: |number:0|plain: |operator:=>|plain: |string:"empty {|variable:$this|string:->name} \n"|punctuation:,
23|plain:            |keyword:default|plain: |operator:=>|plain: |string:'plain'|plain: |punctuation:.|plain: |type:self|operator:::|type:LIMIT|punctuation:,
24|plain:        |punctuation:};
25|plain:    |punctuation:}
26|punctuation:}
== plainText
0|type:Just|plain: |type:some|plain: |plain:words|punctuation:,|plain: |number:1234|plain: |plain:and|plain: |plain:a|plain: |string:"quote"|plain: |function:plus|plain: |punctuation:(|plain:brackets|punctuation:).
1|type:A|plain: |plain:second|plain: |plain:line|plain: |operator:->|plain: |plain:with|plain: |plain:an|plain: |plain:arrow|punctuation:.
== python
0|keyword:from|plain: |plain:__future__|plain: |keyword:import|plain: |plain:annotations
1|
2|keyword:class|plain: |type:Thing|punctuation::
3|plain:    |comment:# a comment
4|plain:    |keyword:def|plain: |function:__init__|punctuation:(|type:self|punctuation:,|plain: |plain:name|punctuation::|plain: |plain:str|plain: |operator:=|plain: |string:"x"|punctuation:)|plain: |operator:->|plain: |constant:None|punctuation::
5|plain:        |type:self|punctuation:.|plain:name|plain: |operator:=|plain: |plain:name
6|plain:        |type:self|punctuation:.|plain:items|plain: |operator:=|plain: |punctuation:[|number:1|punctuation:,|plain: |number:2|punctuation:,|plain: |number:3|punctuation:]
7|
8|plain:    |keyword:async|plain: |keyword:def|plain: |function:run|punctuation:(|type:self|punctuation:,|plain: |operator:*|plain:args|punctuation:,|plain: |operator:**|plain:kwargs|punctuation:):
9|plain:        |keyword:if|plain: |type:self|punctuation:.|plain:name|plain: |keyword:is|plain: |constant:None|plain: |keyword:or|plain: |keyword:not|plain: |plain:args|punctuation::
10|plain:            |keyword:raise|plain: |type:ValueError|punctuation:(|plain:f|string:"bad {self.name!r}"|punctuation:)
11|plain:        |keyword:return|plain: |punctuation:{|plain:k|punctuation::|plain: |plain:v|plain: |keyword:for|plain: |plain:k|punctuation:,|plain: |plain:v|plain: |keyword:in|plain: |plain:kwargs|punctuation:.|function:items|punctuation:()}
== ruby
0|keyword:module|plain: |type:Reporting
1|plain:  |keyword:class|plain: |type:Report|plain: |operator:<|plain: |type:Base
2|plain:    |comment:# a comment
3|plain:    |keyword:def|plain: |function:initialize|punctuation:(|plain:name|punctuation::,|plain: |plain:limit|punctuation::|plain: |number:10|punctuation:)
4|plain:      |punctuation:@|plain:name|plain: |operator:=|plain: |plain:name
5|plain:      |punctuation:@|plain:limit|plain: |operator:=|plain: |plain:limit
6|plain:    |keyword:end
7|
8|plain:    |keyword:def|plain: |plain:to_s
9|plain:      |string:"#{@name} (#{@limit})"
10|plain:    |keyword:end
11|plain:  |keyword:end
12|keyword:end
== rust
0|plain:use|plain: |plain:std|operator:::|plain:collections|operator:::|type:HashMap|punctuation:;
1|
2|punctuation:#[|function:derive|punctuation:(|type:Debug|punctuation:,|plain: |type:Clone|punctuation:)]
3|plain:pub|plain: |keyword:struct|plain: |type:Report|operator:<|string:'a> {
4|plain:    |plain:pub|plain: |plain:name|punctuation::|plain: |operator:&|string:'a str,
5|plain:    |plain:pub|plain: |plain:limit|punctuation::|plain: |plain:u32|punctuation:,
6|punctuation:}
7|
8|plain:impl|operator:<|string:'a> Report<'|plain:a|operator:>|plain: |punctuation:{
9|plain:    |plain:pub|plain: |plain:fn|plain: |keyword:new|punctuation:(|plain:name|punctuation::|plain: |operator:&|string:'a str) -> Self {
10|plain:        |comment:// comment
11|plain:        |type:Self|plain: |punctuation:{|plain: |plain:name|punctuation:,|plain: |plain:limit|punctuation::|plain: |number:0xff|plain: |punctuation:}
12|plain:    |punctuation:}
13|punctuation:}
== shell
0|comment:#!/usr/bin/env bash
1|keyword:set|plain: |operator:-|plain:euo|plain: |plain:pipefail
2|
3|comment:# a comment
4|type:NAME|operator:=|string:"|variable:${1:-bloom}|string:"
5|keyword:for|plain: |plain:file|plain: |keyword:in|plain: |string:"$@"|punctuation:;|plain: |keyword:do
6|plain:  |keyword:if|plain: |punctuation:[[|plain: |operator:-|plain:f|plain: |string:"|variable:$file|string:"|plain: |punctuation:]];|plain: |keyword:then
7|plain:    |plain:echo|plain: |string:"found |variable:$file|string:"
8|plain:  |keyword:else
9|plain:    |keyword:exit|plain: |number:1
10|plain:  |keyword:fi
11|keyword:done
== sql
0|comment:-- a comment
1|keyword:select|plain: |plain:t|punctuation:.|plain:id|punctuation:,|plain: |function:count|punctuation:(|operator:*|punctuation:)|plain: |keyword:as|plain: |plain:total
2|keyword:from|plain: |plain:things|plain: |plain:t
3|keyword:inner|plain: |keyword:join|plain: |plain:owners|plain: |plain:o|plain: |keyword:on|plain: |plain:o|punctuation:.|plain:id|plain: |operator:=|plain: |plain:t|punctuation:.|plain:owner_id
4|keyword:where|plain: |plain:t|punctuation:.|plain:created_at|plain: |operator:>=|plain: |string:'2024-01-01'
5|plain:  |keyword:and|plain: |plain:t|punctuation:.|plain:name|plain: |keyword:like|plain: |string:'%bloom%'
6|keyword:group|plain: |keyword:by|plain: |plain:t|punctuation:.|plain:id
7|keyword:order|plain: |keyword:by|plain: |plain:total|plain: |keyword:desc
8|keyword:limit|plain: |number:10|punctuation:;
== swift
0|keyword:import|plain: |type:Foundation
1|
2|attribute:@MainActor
3|keyword:public|plain: |keyword:struct|plain: |type:Widget|punctuation::|plain: |type:Sendable|plain: |punctuation:{
4|plain:    |comment:// one line
5|plain:    |comment:/* block */
6|plain:    |keyword:private|plain: |keyword:let|plain: |plain:count|punctuation::|plain: |type:Int|plain: |operator:=|plain: |number:0b1010
7|plain:    |keyword:var|plain: |plain:name|punctuation::|plain: |type:String|plain: |punctuation:{|plain: |string:"x"|plain: |punctuation:}
8|
9|plain:    |keyword:func|plain: |function:run|punctuation:()|plain: |keyword:async|plain: |keyword:throws|plain: |operator:->|plain: |punctuation:[|type:String|punctuation:]|plain: |punctuation:{
10|plain:        |keyword:let|plain: |plain:text|plain: |operator:=|plain: |string:"""
11|string:        multi |variable:\(name)|string: line
12|string:        """
13|plain:        |keyword:let|plain: |plain:raw|plain: |operator:=|plain: |string:#"not \(interpolated)"#
14|plain:        |keyword:guard|plain: |plain:count|plain: |operator:!=|plain: |number:0|punctuation:,|plain: |plain:count|plain: |operator:>=|plain: |number:1|plain: |keyword:else|plain: |punctuation:{|plain: |keyword:return|plain: |punctuation:[]|plain: |punctuation:}
15|plain:        |keyword:return|plain: |punctuation:[|plain:text|punctuation:,|plain: |string:"a\u{1F600}b"|punctuation:]
16|plain:    |punctuation:}
17|punctuation:}
== toml
0|comment:# a comment
1|punctuation:[|keyword:package|punctuation:]
2|attribute:name|plain: |operator:=|plain: |string:"bloom"
3|attribute:version|plain: |operator:=|plain: |string:"0.3.0"
4|
5|punctuation:[|plain:dependencies|punctuation:]
6|attribute:serde|plain: |operator:=|plain: |punctuation:{|plain: |attribute:version|plain: |operator:=|plain: |string:"1.0"|punctuation:,|plain: |attribute:features|plain: |operator:=|plain: |punctuation:[|string:"derive"|punctuation:]|plain: |punctuation:}
== typescript
0|keyword:interface|plain: |type:Shape|operator:<|type:T|plain: |keyword:extends|plain: |type:object|operator:>|plain: |punctuation:{
1|plain:  |plain:readonly|plain: |plain:kind|punctuation::|plain: |string:'circle'|plain: |operator:||plain: |string:'square'|punctuation:;
2|plain:  |function:area|punctuation:():|plain: |type:number|punctuation:;
3|punctuation:}
4|
5|keyword:export|plain: |keyword:const|plain: |plain:make|plain: |operator:=|plain: |operator:<|type:T|punctuation:,|operator:>|punctuation:(|plain:x|punctuation::|plain: |type:T|punctuation:):|plain: |type:Shape|operator:<|type:T|operator:>|plain: |operator:=>|plain: |punctuation:({|plain: |plain:kind|punctuation::|plain: |string:'circle'|punctuation:,|plain: |plain:area|punctuation::|plain: |punctuation:()|plain: |operator:=>|plain: |number:1.5e3|plain: |punctuation:});
== vue
0|operator:<|type:template|operator:>
1|plain:  |comment:<!-- comment -->
2|plain:  |operator:<|type:div|plain: |keyword:class|operator:=|string:"card"|plain: |punctuation::|attribute:title|operator:=|string:"name"|plain: |punctuation:@|attribute:click|operator:=|string:"go"|operator:>{{|plain: |plain:name|plain: |operator:}}</|type:div|operator:>
3|operator:</|type:template|operator:>
4|
5|operator:<|type:script|plain: |attribute:setup|operator:>
6|keyword:import|plain: |punctuation:{|plain: |plain:ref|plain: |punctuation:}|plain: |plain:from|plain: |string:'vue'|punctuation:;
7|keyword:const|plain: |plain:name|plain: |operator:=|plain: |function:ref|punctuation:(|string:'bloom'|punctuation:);
8|operator:</|type:script|operator:>
== xml
0|operator:<?|attribute:xml|plain: |attribute:version|operator:=|string:"1.0"|plain: |attribute:encoding|operator:=|string:"UTF-8"|operator:?>
1|comment:<!-- a comment -->
2|operator:<|type:plist|plain: |attribute:version|operator:=|string:"1.0"|operator:>
3|plain:  |operator:<|type:dict|operator:>
4|plain:    |operator:<|type:key|operator:>|type:CFBundleName|operator:</|type:key|operator:>
5|plain:    |operator:<|type:string|operator:>|type:Bloom|operator:</|type:string|operator:>
6|plain:  |operator:</|type:dict|operator:>
7|operator:</|type:plist|operator:>
== yaml
0|comment:# a comment
1|attribute:name|punctuation::|plain: |plain:bloom
2|attribute:on|punctuation::
3|plain:  |attribute:push|punctuation::
4|plain:    |attribute:branches|punctuation::|plain: |punctuation:[|plain:main|punctuation:]
5|attribute:jobs|punctuation::
6|plain:  |attribute:test|punctuation::
7|plain:    |plain:runs|operator:-|attribute:on|punctuation::|plain: |plain:macos|operator:-|number:26
8|plain:    |attribute:steps|punctuation::
9|plain:      |operator:-|plain: |attribute:uses|punctuation::|plain: |plain:actions|operator:/|plain:checkout|punctuation:@|plain:v4
10|plain:      |operator:-|plain: |attribute:run|punctuation::|plain: |operator:|
11|plain:          |plain:make|plain: |plain:test
"""#
