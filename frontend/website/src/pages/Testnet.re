module Styles = {
  open Css;

  let markdownStyles =
    style([
      selector("a", [cursor(`pointer), ...Theme.Link.basicStyles]),
      selector(
        "h4",
        Theme.H4.wideStyles
        @ [textAlign(`left), fontSize(`rem(1.)), fontWeight(`light)],
      ),
      selector(
        "code",
        [Theme.Typeface.pragmataPro, color(Theme.Colors.midnight)],
      ),
      selector(
        "p > code, li > code",
        [
          boxSizing(`borderBox),
          padding2(~v=`px(2), ~h=`px(6)),
          backgroundColor(Theme.Colors.slateAlpha(0.05)),
          borderRadius(`px(4)),
        ],
      ),
    ]);

  let page =
    style([
      selector(
        "hr",
        [
          height(px(4)),
          borderTop(px(1), `dashed, Theme.Colors.marine),
          borderLeft(`zero, solid, transparent),
          borderBottom(px(1), `dashed, Theme.Colors.marine),
        ],
      ),
    ]);

  let header =
    style([
      display(`flex),
      flexDirection(`column),
      width(`percent(100.)),
      color(Theme.Colors.slate),
      textAlign(`center),
      margin2(~v=rem(3.5), ~h=`zero),
    ]);

  let content =
    style([
      display(`flex),
      justifyContent(`center),
      flexDirection(`column),
      width(`percent(100.)),
      marginBottom(`rem(1.5)),
    ]);

  let leaderboardCopy =
    style([maxWidth(`rem(36.5)), margin2(~v=`zero, ~h=`auto)]);

  let rowStyles = [
    display(`grid),
    gridColumnGap(rem(1.5)),
    gridTemplateColumns([rem(1.), rem(5.5), rem(5.5), rem(3.5)]),
    media(
      Theme.MediaQuery.notMobile,
      [
        width(`percent(100.)),
        gridTemplateColumns([rem(2.5), `auto, rem(6.), rem(3.5)]),
      ],
    ),
  ];

  let copy =
    style([
      maxWidth(rem(28.)),
      margin3(~top=`zero, ~h=`auto, ~bottom=rem(2.)),
      media(Theme.MediaQuery.somewhatLarge, [marginLeft(rem(5.))]),
      media(Theme.MediaQuery.notMobile, [width(rem(28.))]),
      ...Theme.Body.basicStyles,
    ]);

  let headerLink =
    merge([
      Theme.Link.basic,
      Theme.H3.basic,
      style([
        fontWeight(`semiBold),
        marginTop(rem(1.5)),
        marginLeft(rem(1.75)),
      ]),
    ]);

  let sidebarHeader =
    merge([
      Theme.H4.wide,
      style([textAlign(`left), fontSize(`rem(1.)), fontWeight(`light)]),
    ]);

  let dashboardHeader =
    merge([
      header,
      style([marginTop(rem(1.5)), marginBottom(`rem(1.5))]),
    ]);

  let dashboard =
    style([
      width(`percent(100.)),
      height(`rem(70.)),
      border(`px(0), `solid, white),
      borderRadius(px(3)),
    ]);

  let expandButton =
    merge([
      Theme.Link.basic,
      style([
        backgroundColor(Theme.Colors.hyperlink),
        color(white),
        marginLeft(`auto),
        marginRight(`auto),
        marginBottom(`rem(1.5)),
        display(`flex),
        cursor(`pointer),
        borderRadius(`px(4)),
        padding2(~v=`rem(0.25), ~h=`rem(3.)),
        fontWeight(`semiBold),
        lineHeight(`rem(2.5)),
        hover([backgroundColor(Theme.Colors.hyperlinkHover), color(white)]),
      ]),
    ]);

  let gradientSectionExpanded =
    style([
      height(`auto),
      width(`percent(100.)),
      position(`relative),
      overflow(`hidden),
      display(`flex),
      flexWrap(`wrap),
      marginLeft(`auto),
      marginRight(`auto),
      justifyContent(`center),
    ]);

  let gradientSection =
    merge([
      gradientSectionExpanded,
      style([
        height(`rem(45.)),
        after([
          contentRule(""),
          position(`absolute),
          bottom(`px(-1)),
          left(`zero),
          height(`rem(8.)),
          width(`percent(100.)),
          pointerEvents(`none),
          backgroundImage(
            `linearGradient((
              `deg(0.),
              [
                (`zero, Theme.Colors.white),
                (`percent(100.), Theme.Colors.whiteAlpha(0.)),
              ],
            )),
          ),
        ]),
      ]),
    ]);

  let buttonRow =
    style([
      display(`grid),
      gridTemplateColumns([`fr(1.0)]),
      gridRowGap(rem(1.5)),
      gridTemplateRows([`repeat((`num(4), `rem(6.0)))]),
      justifyContent(`center),
      marginLeft(`auto),
      marginRight(`auto),
      marginTop(rem(3.)),
      marginBottom(rem(3.)),
      media(
        "(min-width: 45rem)",
        [
          gridTemplateColumns([`repeat((`num(2), `fr(1.0)))]),
          gridTemplateRows([`repeat((`num(2), `rem(6.0)))]),
          gridColumnGap(rem(1.5)),
        ],
      ),
      media(
        "(min-width: 66rem)",
        [
          gridTemplateColumns([`repeat((`num(2), `fr(1.0)))]),
          gridTemplateRows([`repeat((`num(2), `rem(5.4)))]),
        ],
      ),
      media(
        "(min-width: 70rem)",
        [
          gridTemplateColumns([`repeat((`num(4), `fr(1.0)))]),
          gridTemplateRows([`repeat((`num(1), `rem(7.5)))]),
          gridColumnGap(rem(1.0)),
        ],
      ),
    ]);

  let discordIcon = style([marginTop(`px(-4))]);
  let formIcon = style([marginTop(`px(3))]);
  let heroRow =
    style([
      display(`flex),
      flexDirection(`column),
      justifyContent(`spaceBetween),
      alignItems(`center),
      media("(min-width: 70rem)", [flexDirection(`row)]),
    ]);

  let heroText =
    merge([header, style([maxWidth(`px(500)), textAlign(`left)])]);
  let disclaimer =
    merge([Theme.Body.small, style([color(Theme.Colors.midnight)])]);

  let leaderboardLink = style([textDecoration(`none)]);

  let signUpContainer =
    style([
      display(`flex),
      flexDirection(`column),
      alignItems(`center),
      justifyContent(`spaceBetween),
      marginTop(`rem(1.)),
      media(Theme.MediaQuery.notMobile, [flexDirection(`row)]),
      selector(
        "a",
        [
          important(maxWidth(`rem(10.))),
          important(height(`percent(100.))),
          media(Theme.MediaQuery.tablet, [marginTop(`rem(0.5))]),
        ],
      ),
    ]);
};

module Section = {
  [@react.component]
  let make = (~name, ~expanded, ~setExpanded, ~children, ~link=?) => {
    <div className=Css.(style([display(`flex), flexDirection(`column)]))>
      {if (expanded) {
         <div className=Styles.gradientSectionExpanded> children </div>;
       } else {
         <>
           <div className=Styles.gradientSection> children </div>
           <div
             className=Styles.expandButton
             onClick={_ =>
               switch (link) {
               | Some(dest) => ReasonReactRouter.push(dest)
               | None => setExpanded(_ => true)
               }
             }>
             <div> {React.string("View Full " ++ name)} </div>
           </div>
         </>;
       }}
    </div>;
  };
};

[@react.component]
let make = (~challenges as _, ~testnetName as _) => {
  let (expanded, setExpanded) = React.useState(() => false);
  <Page title="Coda Testnet">
    <Wrapped>
      <div className=Styles.page>
        <div className=Styles.heroRow>
          <div className=Styles.heroText>
            <h1 className=Theme.H1.hero>
              {React.string("Coda Public Testnet")}
            </h1>
            <p className=Theme.Body.basic>
              {React.string(
                 "Coda's public testnet is live! During testnet releases, there are challenges for the community to interact with the testnet and contribute to Coda's development. Top contributors will be recognized and rewarded with testnet points.",
               )}
            </p>
            <br />
            <p className=Theme.Body.basic>
              {React.string(
                 "Later this year Coda will begin its adversarial testnet, 'Testworld', where users can earn Coda tokens, USD, and token delegations for participating.",
               )}
            </p>
            <div className=Styles.signUpContainer>
              <Button
                link="/adversarial"
                label="Sign Up Now"
                bgColor=Theme.Colors.jungle
                bgColorHover={Theme.Colors.hyperlinkAlpha(1.)}
              />
              <span
                className=Css.(
                  style([
                    display(`flex),
                    alignItems(`center),
                    justifyContent(`center),
                  ])
                )>
                <p className=Theme.Body.basic>
                  {React.string("Testnet Status: ")}
                  <StatusBadge service=`Network />
                </p>
              </span>
            </div>
          </div>
          <Terminal.Wrapper lineDelay=2000>
            <Terminal.Line prompt=">" value="coda daemon -peer ..." />
            <Terminal.Progress />
            <Terminal.MultiLine
              values=[|"Daemon ready. Clients can now connect!"|]
            />
            <Terminal.Line prompt=">" value="coda client status" />
            <Terminal.MultiLine
              values=[|
                "Max observed block length: 120",
                "Peers: 23",
                "Consensus time now: epoch=1, slot=13",
                "Sync status: Synced",
              |]
            />
          </Terminal.Wrapper>
        </div>
        <div>
          <div className=Styles.buttonRow>
            <ActionButton
              icon={React.string({js| 🚥 |js})}
              heading={React.string({js| Get Started |js})}
              text={React.string(
                "Get started by installing Coda and running a node",
              )}
              href="/docs/getting-started/"
            />
            <ActionButton
              icon={
                <img
                  className=Styles.discordIcon
                  src="/static/img/discord.svg"
                />
              }
              heading={React.string({js| Discord |js})}
              text={React.string(
                "Connect with the community and participate in weekly challenges",
              )}
              href="https://bit.ly/CodaDiscord"
            />
            <ActionButton
              icon={React.string({js|💬|js})}
              heading={React.string({js| Forum |js})}
              text={React.string(
                "Find longer discussions and in-depth content",
              )}
              href="https://forums.codaprotocol.com/"
            />
            <ActionButton
              icon={React.string({js| 🌟 |js})}
              heading={React.string({js| Token Grant |js})}
              text={React.string(
                "Apply to be one of the early members to receive a Genesis token grant",
              )}
              href="/genesis"
            />
          </div>
        </div>
        <hr />
        <Section name="Leaderboard" expanded setExpanded link="/leaderboard">
          <div className=Styles.dashboardHeader>
            <h1 className=Theme.H1.hero>
              {React.string("Testnet Leaderboard")}
            </h1>
            // href="https://testnet-points-frontend-dot-o1labs-192920.appspot.com/"
            <a href="/leaderboard" className=Styles.headerLink>
              {React.string({j|View Full Leaderboard\u00A0→|j})}
            </a>
          </div>
          <div className=Styles.content>
            <span className=Styles.leaderboardCopy>
              <p className=Theme.Body.big_semibold>
                {React.string(
                   "Coda rewards community members with testnet points for completing challenges that \
                  contribute to the development of the protocol. *",
                 )}
              </p>
              <p className=Styles.disclaimer>
                {React.string(
                   "* Testnet Points are designed solely to track contributions to the Testnet \
                 and Testnet Points have no cash or other monetary value. Testnet Points and \
                 are not transferable and are not redeemable or exchangeable for any cryptocurrency \
                 or digital assets. We may at any time amend or eliminate Testnet Points.",
                 )}
              </p>
            </span>
            <a href="/leaderboard" className=Styles.leaderboardLink>
              <Leaderboard interactive=false />
            </a>
          </div>
        </Section>
        <hr />
        <div>
          <div className=Styles.dashboardHeader>
            <h1 className=Theme.H1.hero>
              {React.string("Network Dashboard")}
            </h1>
            <a
              href="https://o1testnet.grafana.net/d/Rgo87HhWz/block-producer-dashboard?orgId=1"
              target="_blank"
              className=Styles.headerLink>
              {React.string({j|View Full Dashboard\u00A0→|j})}
            </a>
          </div>
          <iframe
            src="https://o1testnet.grafana.net/d/qx4y6dfWz/network-overview?orgId=1&refresh=1m"
            className=Styles.dashboard
          />
        </div>
      </div>
    </Wrapped>
  </Page>;
};

Next.injectGetInitialProps(make, _ =>
  Challenges.fetchAllChallenges()
  |> Promise.map(((testnetName, ranking, continuous, threshold)) =>
       {
         "challenges": (ranking, continuous, threshold),
         "testnetName": testnetName,
       }
     )
);
