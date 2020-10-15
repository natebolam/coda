module Styles = {
  open Css;
  let page =
    style([
      marginLeft(`auto),
      marginRight(`auto),
      display(`flex),
      width(`percent(100.)),
      flexDirection(`column),
      justifyContent(`spaceBetween),
      alignContent(`spaceAround),
      media(Theme.MediaQuery.tablet, [maxWidth(`rem(68.))]),
    ]);

  let container =
    style([
      height(`rem(40.)),
      display(`flex),
      flexDirection(`column),
      justifyContent(`spaceBetween),
    ]);
  let documentationButton =
    style([textAlign(`left), height(`rem(2.)), width(`rem(7.18))]);
  let joinGenesisButton =
    style([color(white), width(`rem(5.75)), height(`rem(2.))]);
};

[@react.component]
let make = () => {
  <Page title="Demo page of components">
    <div className=Nav.Styles.spacer />
    <div className=Styles.page>
      <div>
        <SideNav currentSlug="">
          <SideNav.Item title="Overview" slug="" />
          <SideNav.Item title="Getting Started" slug="getting-started" />
          <SideNav.Section title="Developers" slug="developers">
            <SideNav.Item title="Developers Overview" slug="" />
            <SideNav.Item title="Codebase Overview" slug="codebase-overview" />
          </SideNav.Section>
          <SideNav.Section title="SNARKs" slug="snarks">
            <SideNav.Item title="SNARKs Overview" slug="" />
          </SideNav.Section>
          <SideNav.Item title="Archive Node" slug="archive-node" />
          <SideNav.Item title="Snapps" slug="snapps" />
          <SideNav.Item title="Glossary" slug="glossary" />
        </SideNav>
      </div>
      <div className=Styles.container>
        /*** Regular buttons */

          <Button href=`Scroll_to_top bgColor=Theme.Colors.orange>
            {React.string("Button Label")}
            <Icon kind=Icon.ArrowRightMedium />
          </Button>
          <Button href=`Scroll_to_top bgColor=Theme.Colors.mint dark=true>
            {React.string("Button label ")}
            <Icon kind=Icon.ArrowRightMedium />
          </Button>
          <Button href=`Scroll_to_top bgColor=Theme.Colors.black>
            {React.string("Button label")}
            <Icon kind=Icon.ArrowRightMedium />
          </Button>
          <Button href=`Scroll_to_top bgColor=Theme.Colors.white>
            {React.string("Button label")}
            <Icon kind=Icon.ArrowRightMedium />
          </Button>
          /*** Documentation Button TODO: Add link for documentation */
          <PromoButton bgColor=Theme.Colors.orange>
            <Icon kind=Icon.Documentation size=2.5 />
            <span className=Styles.documentationButton>
              {React.string("Go To Documentation")}
            </span>
          </PromoButton>
          /***Join Genesis Button, uses the CoreProtocolLarge icon */
          <Button
            href=`Scroll_to_top
            bgColor=Theme.Colors.orange
            paddingX=1.
            paddingY=0.5>
            <Icon kind=Icon.CoreProtocolLarge size=2.5 />
            <span className=Styles.joinGenesisButton>
              {React.string("Join Genesis + Earn Mina")}
            </span>
          </Button>
        </div>
      <h1 className=Theme.Type.h1jumbo> {React.string("H1 Jumbo")} </h1>
      <h1 className=Theme.Type.h1> {React.string("H1")} </h1>
      <h2 className=Theme.Type.h2> {React.string("H2")} </h2>
      <h3 className=Theme.Type.h3> {React.string("H3")} </h3>
      <h4 className=Theme.Type.h4> {React.string("H4")} </h4>
      <h5 className=Theme.Type.h4> {React.string("H5")} </h5>
      <h6 className=Theme.Type.h4> {React.string("H6")} </h6>
      <div className=Theme.Type.pageLabel> {React.string("Page label")} </div>
      <div className=Theme.Type.label> {React.string("Label")} </div>
      <div className=Theme.Type.buttonLabel>
        {React.string("Button label")}
      </div>
      <a className=Theme.Type.link> {React.string("Link")} </a>
      <a className=Theme.Type.navLink> {React.string("Nav Link")} </a>
      <a className=Theme.Type.sidebarLink> {React.string("Sidebar Link")} </a>
      <div className=Theme.Type.tooltip> {React.string("Tooltip")} </div>
      <div className=Theme.Type.creditName>
        {React.string("Credit name")}
      </div>
      <div className=Theme.Type.metadata> {React.string("Metadata")} </div>
      <div className=Theme.Type.announcement>
        {React.string("Announcement")}
      </div>
      <div className=Theme.Type.errorMessage>
        {React.string("Error message")}
      </div>
      <div className=Theme.Type.pageSubhead>
        {React.string(
           "Page subhead / Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod temporus incididunt ut labore et dolore.",
         )}
      </div>
      <div className=Theme.Type.sectionSubhead>
        {React.string(
           "Section Subhead / Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod temporus incididunt ut labore et.",
         )}
      </div>
      <p className=Theme.Type.paragraph>
        {React.string(
           "Paragraph (Grotesk) / Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
         )}
      </p>
      <p className=Theme.Type.paragraphSmall>
        {React.string(
           "Paragraph Small (Grotesk) / Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
         )}
      </p>
      <p className=Theme.Type.paragraphMono>
        {React.string(
           "Paragraph (Mono) / Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmodorus temporus incididunt ut labore et dolore.",
         )}
      </p>
      <p className=Theme.Type.quote>
        {React.string(
           "Quote / Lorem ipsum dolor sit amet, consectetur amet adipiscing elit, sed do eiusmod tempor.",
         )}
      </p>
      <AlternatingSections
        backgroundImg=""
        sections={
          AlternatingSections.Section.SimpleRow([|
            {
              AlternatingSections.Section.SimpleRow.title: "Run a Node",
              description: "You don't have to have expensive hardware, wait days for the blockchain to sync, or use a ton of compute power to participate in consensus. Just follow clear, straightforward instructions and connect to the live peer-to-peer Mina network.",
              buttonCopy: "Get Started",
              buttonUrl: `Internal("/"),
              image: "/static/img/ProgrammableMoney.png",
            },
          |])
        }
      />
    </div>
    <ButtonBar
      kind=ButtonBar.HelpAndSupport
      backgroundImg="/static/img/ButtonBarBackground.jpg"
    />
    <ButtonBar
      kind=ButtonBar.CommunityLanding
      backgroundImg="/static/img/ButtonBarBackground.jpg"
    />
  </Page>;
};
