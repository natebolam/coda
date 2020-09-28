open Jest;
open Expect;
module StringMap = Map.Make(String);

let blocks = [|
  {
    Types.Block.id: 1,
    blockchainState: {
      creatorAccount: "publickey1",
      timestamp: "0",
      height: "1",
    },
    userCommands: [||],
    internalCommands: [||],
  },
  {
    id: 2,
    blockchainState: {
      creatorAccount: "publickey1",
      timestamp: "1548878462542",
      height: "2",
    },
    userCommands: [||],
    internalCommands: [||],
  },
  {
    id: 3,
    blockchainState: {
      creatorAccount: "publickey1",
      timestamp: "1548878464058",
      height: "3",
    },
    userCommands: [||],
    internalCommands: [||],
  },
  {
    id: 4,
    blockchainState: {
      creatorAccount: "publickey1",
      timestamp: "1548878466000",
      height: "4",
    },
    userCommands: [||],
    internalCommands: [||],
  },
  {
    id: 5,
    blockchainState: {
      creatorAccount: "publickey2",
      timestamp: "1548878468000",
      height: "5",
    },
    userCommands: [||],
    internalCommands: [||],
  },
  {
    id: 6,
    blockchainState: {
      creatorAccount: "publickey2",
      timestamp: "1548878470000",
      height: "6",
    },
    userCommands: [||],
    internalCommands: [||],
  },
  {
    id: 7,
    blockchainState: {
      creatorAccount: "publickey2",
      timestamp: "1548878472000",
      height: "7",
    },
    userCommands: [||],
    internalCommands: [||],
  },
  {
    id: 8,
    blockchainState: {
      creatorAccount: "publickey3",
      timestamp: "1548878474000",
      height: "8",
    },
    userCommands: [||],
    internalCommands: [||],
  },
  {
    id: 9,
    blockchainState: {
      creatorAccount: "publickey3",
      timestamp: "1548878476000",
      height: "9",
    },
    userCommands: [||],
    internalCommands: [||],
  },
  {
    id: 10,
    blockchainState: {
      creatorAccount: "publickey4",
      timestamp: "1548878478000",
      height: "10",
    },
    userCommands: [||],
    internalCommands: [||],
  },
|];

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
        Points.addPointsToUsersWithAtleastN(
          (metricRecord: Types.Metrics.t) => metricRecord.blocksCreated,
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
        Points.addPointsToUsersWithAtleastN(
          (metricRecord: Types.Metrics.t) => metricRecord.blocksCreated,
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
        Points.applyTopNPoints(
          [|(2, 1000)|],
          blockMetrics,
          (metricRecord: Types.Metrics.t) => metricRecord.blocksCreated,
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
        Points.applyTopNPoints(
          [|(0, 2000), (2, 1000)|],
          blockMetrics,
          (metricRecord: Types.Metrics.t) => metricRecord.blocksCreated,
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
        Points.applyTopNPoints(
          [|(0, 3000), (1, 2000), (5, 1000)|],
          blockMetrics,
          (metricRecord: Types.Metrics.t) => metricRecord.blocksCreated,
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
