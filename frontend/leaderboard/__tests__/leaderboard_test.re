open Jest;
open Expect;
module StringMap = Map.Make(String);

let blockChallenge = "Stake your Coda and produce blocks";

let blockDirectory =
  ([%bs.node __dirname] |> Belt.Option.getExn |> Filename.dirname)
  ++ "/../../__tests__/blocks/";

let blocks =
  blockDirectory
  |> Node.Fs.readdirSync
  |> Array.map(file => {
       let fileContents = Node.Fs.readFileAsUtf8Sync(blockDirectory ++ file);
       let blockData = Js.Json.parseExn(fileContents);
       let block = Types.NewBlock.unsafeJSONToNewBlock(blockData);
       block.data.newBlock;
     });

describe("Metrics", () => {
  describe("blocksCreatedMetric", () => {
    let blockMetrics = Metrics.getBlocksCreatedByUser(blocks);
    test("correct number of users exist in the metrics map", () => {
      expect(StringMap.cardinal(blockMetrics)) |> toBe(4)
    });
    test("correct number of blocks for publickey1", () => {
      expect(StringMap.find("publickey1", blockMetrics)) |> toBe(4)
    });
    test("correct number of blocks for publickey2", () => {
      expect(StringMap.find("publickey2", blockMetrics)) |> toBe(3)
    });
    test("correct number of blocks for publickey3", () => {
      expect(StringMap.find("publickey3", blockMetrics)) |> toBe(2)
    });
    test("correct number of blocks for publickey4", () => {
      expect(StringMap.find("publickey4", blockMetrics)) |> toBe(1)
    });
    test("publickey5 does not exist in metrics map", () => {
      expect(() =>
        StringMap.find("publickey5", blockMetrics)
      )
      |> toThrowException(Not_found)
    });
  })
});

describe("Points functions", () => {
  let blockMetrics = blocks |> Metrics.calculateMetrics;
  describe("addPointsToAtleastN", () => {
    describe("adds correct number of points with atleast 1", () => {
      let blockPoints =
        Challenges.addPointsToUsersWithAtleastN(
          (metricRecord: Types.Metrics.metricRecord) =>
            metricRecord.blocksCreated,
          1,
          1000,
          blockMetrics,
        );

      test("correct number of points given to publickey1", () => {
        expect(StringMap.find("publickey1", blockPoints)) |> toBe(1000)
      });
      test("correct number of points given to publickey2", () => {
        expect(StringMap.find("publickey2", blockPoints)) |> toBe(1000)
      });
      test("correct number of points given to publickey3", () => {
        expect(StringMap.find("publickey3", blockPoints)) |> toBe(1000)
      });
      test("publickey8 does not exist in points map", () => {
        expect(() =>
          StringMap.find("publickey8", blockPoints)
        )
        |> toThrowException(Not_found)
      });
    });
    describe("adds correct number of points with atleast 3", () => {
      let blockPoints =
        Challenges.addPointsToUsersWithAtleastN(
          (metricRecord: Types.Metrics.metricRecord) =>
            metricRecord.blocksCreated,
          3,
          1000,
          blockMetrics,
        );
      test("correct number of points given to publickey1", () => {
        expect(StringMap.find("publickey1", blockPoints)) |> toBe(1000)
      });
      test("correct number of points given to publickey2", () => {
        expect(StringMap.find("publickey2", blockPoints)) |> toBe(1000)
      });
      test("publickey3 does not exist in points map", () => {
        expect(() =>
          StringMap.find("publickey3", blockPoints)
        )
        |> toThrowException(Not_found)
      });
    });
  });
  describe("applyTopNPoints", () => {
    describe("adds correct number of points to top 3", () => {
      let blockPoints =
        Challenges.applyTopNPoints(
          [|(2, 1000)|],
          blockMetrics,
          (metricRecord: Types.Metrics.metricRecord) =>
            metricRecord.blocksCreated,
          compare,
        );
      test("correct number of points given to publickey1", () => {
        expect(StringMap.find("publickey1", blockPoints)) |> toBe(1000)
      });
      test("correct number of points given to publickey2", () => {
        expect(StringMap.find("publickey2", blockPoints)) |> toBe(1000)
      });
      test("correct number of points given to publickey3", () => {
        expect(StringMap.find("publickey3", blockPoints)) |> toBe(1000)
      });
      test("publickey4 does not exist in points map", () => {
        expect(() =>
          StringMap.find("publickey4", blockPoints)
        )
        |> toThrowException(Not_found)
      });
    });
    describe("adds correct number of points to 1st place and 2-3 place", () => {
      let blockPoints =
        Challenges.applyTopNPoints(
          [|(0, 2000), (2, 1000)|],
          blockMetrics,
          (metricRecord: Types.Metrics.metricRecord) =>
            metricRecord.blocksCreated,
          compare,
        );
      test("correct number of points given to publickey1", () => {
        expect(StringMap.find("publickey1", blockPoints)) |> toBe(2000)
      });
      test("correct number of points given to publickey2", () => {
        expect(StringMap.find("publickey2", blockPoints)) |> toBe(1000)
      });
      test("correct number of points given to publickey3", () => {
        expect(StringMap.find("publickey3", blockPoints)) |> toBe(1000)
      });
      test("publickey4 does not exist in points map", () => {
        expect(() =>
          StringMap.find("publickey4", blockPoints)
        )
        |> toThrowException(Not_found)
      });
    });
    describe(
      "adds correct number of points to 1st and 2nd place and 3-4 place", () => {
      let blockPoints =
        Challenges.applyTopNPoints(
          [|(0, 3000), (1, 2000), (5, 1000)|],
          blockMetrics,
          (metricRecord: Types.Metrics.metricRecord) =>
            metricRecord.blocksCreated,
          compare,
        );
      test("correct number of points given to publickey1", () => {
        expect(StringMap.find("publickey1", blockPoints)) |> toBe(3000)
      });
      test("correct number of points given to publickey2", () => {
        expect(StringMap.find("publickey2", blockPoints)) |> toBe(2000)
      });
      test("correct number of points given to publickey3", () => {
        expect(StringMap.find("publickey3", blockPoints)) |> toBe(1000)
      });
      test("correct number of points given to publickey4", () => {
        expect(StringMap.find("publickey4", blockPoints)) |> toBe(1000)
      });
    });
  });
});