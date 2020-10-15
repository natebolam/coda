module Styles = {
  open Css;
  let container =
    style([
      position(`relative),
      width(`percent(100.)),
      height(`rem(35.8)),
    ]);
  let text =
    style([
      top(`rem(4.)),
      left(`zero),
      position(`absolute),
      backgroundColor(Theme.Colors.purple),
      padding2(~v=`rem(2.5), ~h=`rem(2.5)),
      width(`rem(23.)),
      height(`rem(14.3)),
      display(`flex),
      flexDirection(`column),
    ]);
  let header = merge([Theme.Type.h3, style([color(white)])]);
  let sectionSubhead =
    merge([
      Theme.Type.paragraphMono,
      style([
        color(white),
        letterSpacing(`pxFloat(-0.4)),
        marginTop(`rem(1.)),
        fontSize(`rem(1.18)),
      ]),
    ]);
  let remainingSpots =
    style([
      position(`absolute),
      bottom(`zero),
      left(`zero),
      backgroundColor(Theme.Colors.white),
      padding2(~v=`rem(2.5), ~h=`rem(2.5)),
      width(`rem(23.)),
      height(`rem(11.25)),
      display(`grid),
      gridTemplateColumns([`rem(10.75), `rem(6.25)]),
      gridColumnGap(`rem(1.)),
      color(black),
    ]);
  let worldMapImage =
    style([
      display(`none),
      media(Theme.MediaQuery.desktop, [display(`grid)]),
      position(`absolute),
      right(`rem(-5.)),
      width(`rem(50.)),
      height(`rem(30.8)),
    ]);
  let activeMembers =
    style([
      position(`absolute),
      bottom(`zero),
      right(`rem(35.5)),
      height(`rem(9.375)),
      zIndex(99),
      width(`rem(8.375)),
      display(`none),
      media(Theme.MediaQuery.desktop, [display(`grid)]),
    ]);
  let number =
    style([
      Theme.Typeface.monumentGrotesk,
      fontSize(`rem(4.)),
      lineHeight(`rem(4.)),
    ]);
  let mintNumber = merge([number, style([color(Theme.Colors.mint)])]);
  let label =
    merge([
      Theme.Type.label,
      style([
        important(fontSize(`px(14))),
        important(lineHeight(`px(16))),
        letterSpacing(`em(0.03)),
      ]),
    ]);
  let icon = style([color(white)]);
  let whiteLabel = merge([label, style([color(white)])]);
};
[@react.component]
let make = () => {
  <div className=Styles.container>
    <>
      <div className=Styles.text>
        <h2 className=Styles.header>
          {React.string("A Growing Global Community")}
        </h2>
        <span className=Styles.sectionSubhead>
          {React.string("See where Genesis members are around the world ->")}
        </span>
      </div>
      <div className=Styles.remainingSpots>
        <div>
          <p className=Styles.number> {React.string("850")} </p>
          <span className=Styles.label>
            {React.string("Genesis Spots Remaining")}
          </span>
        </div>
        <span className=Styles.icon>
          <Icon kind=Icon.GenesisProgram size=6.25 />
        </span>
      </div>
    </>
    <>
      <img
        className=Styles.worldMapImage
        src="/static/svg/World_Map_Illustration.svg"
      />
      <div className=Styles.activeMembers>
        <p className=Styles.mintNumber> {React.string("150")} </p>
        <span className=Styles.whiteLabel>
          {React.string("Active Genesis Members")}
        </span>
      </div>
    </>
  </div>;
};
