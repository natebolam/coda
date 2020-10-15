module Styles = {
  open Css;

  let background =
    style([
      backgroundImage(
        `url("/static/img/BecomeAGenesisMemberBackground.jpg"),
      ),
      backgroundSize(`cover),
    ]);
};

[@react.component]
let make = () => {
  <Page title="Mina Cryptocurrency Protocol" footerColor=Theme.Colors.orange>
    <div className=Nav.Styles.spacer />
    <Hero
      title="Get Started"
      header="Mina makes it simple."
      copy={
        Some(
          "Interested and ready to take the next step? You're in the right place.",
        )
      }
      background={
        Theme.desktop: "/static/img/backgrounds/04_GetStarted_1_2880x1504.jpg",
        Theme.tablet: "/static/img/backgrounds/04_GetStarted_1_1536x1504_tablet.jpg",
        Theme.mobile: "/static/img/backgrounds/04_GetStarted_1_750x1056_mobile.jpg",
      }
    />
    <ButtonBar
      kind=ButtonBar.GetStarted
      backgroundImg="/static/img/ButtonBarBackground.jpg"
    />
    <AlternatingSections
      backgroundImg="/static/img/MinaSimplePattern1.jpg"
      sections={
        AlternatingSections.Section.SimpleRow([|
          {
            AlternatingSections.Section.SimpleRow.title: "Run a Node",
            description: "Other protocols are so heavy they require intermediaries to run nodes, recreating the same old power dynamics. But Mina is light, so anyone can connect peer-to-peer and sync and verify the chain in seconds. Built on a consistent-sized cryptographic proof, the blockchain will stay accessible - even as it scales to millions of users.",
            buttonCopy: "Explore the Tech",
            buttonUrl: `Internal("/docs/getting-started"),
            image: "/static/img/rowImages/RunANode.jpg",
          },
          {
            title: "Build on Mina",
            description: "Interested in building decentralized apps that use SNARKs to verify off-chain data with full verifiability, privacy and scaling? Just download the SDK, follow our step-by-step documentation and put your imagination to work.",
            buttonCopy: "Run a node",
            buttonUrl: `Internal("/docs/getting-started"),
            image: "/static/img/rowImages/BuildOnMina.jpg",
          },
          {
            title: "Join the Community",
            description: "Mina is an inclusive open source project uniting people around the world with a passion for decentralized technology and building what's next.",
            buttonCopy: "See what we're up to",
            buttonUrl: `Internal("/community"),
            image: "/static/img/rowImages/JoinCommunity.jpg",
          },
          {
            title: "Apply for a Grant",
            description: "From front-end sprints and protocol development to community building initiatives and content creation, our Grants Program invites you to help strengthen the network in exchange for Mina tokens.",
            buttonCopy: "Learn More",
            buttonUrl: `Internal("/docs/contributing#mina-grants"),
            image: "/static/img/rowImages/ApplyForGrant.jpg",
          },
        |])
      }
    />
    <div className=Styles.background>
      <FeaturedSingleRow
        row={
          FeaturedSingleRow.Row.rowType: ImageLeftCopyRight,
          title: "Become a Genesis Member",
          copySize: `Small,
          description: "Up to 1,000 community participants will be selected to help us harden Mina's protocol, strengthen the network and receive a distribution of 66,000 tokens.",
          textColor: Theme.Colors.white,
          image: "/static/img/GenesisCopy.jpg",
          background: Image("/static/img/BecomeAGenesisMemberBackground.jpg"),
          contentBackground: Image("/static/img/BecomeAGenesisMember.jpg"),
          link:
            FeaturedSingleRow.Row.Button({
              FeaturedSingleRow.Row.buttonText: "Learn More",
              buttonColor: Theme.Colors.orange,
              buttonTextColor: Theme.Colors.white,
              dark: false,
              href: `Internal("/genesis"),
            }),
        }
      />
    </div>
    <ButtonBar
      kind=ButtonBar.HelpAndSupport
      backgroundImg="/static/img/ButtonBarBackground.jpg"
    />
  </Page>;
};
