import { Alert, Layout } from "antd";
import Config from "components/account/config";
import A from "components/misc/A";
import { join } from "path";
import basePath from "lib/base-path";
import ConfigMenu from "./menu";
import useIsBrowser from "lib/hooks/is-browser";
import useCustomize from "lib/use-customize";
import InPlaceSignInOrUp from "components/auth/in-place-sign-in-or-up";
import { menu } from "./register";
import { Icon } from "@cocalc/frontend/components/icon";

const { Content, Sider } = Layout;

interface Props {
  page: string;
}

export default function ConfigLayout({ page }: Props) {
  const isBrowser = useIsBrowser();
  const { account } = useCustomize();

  if (!account) {
    return (
      <Alert
        style={{ margin: "15px auto" }}
        type="warning"
        message={
          <InPlaceSignInOrUp
            title="Account Configuration"
            why="to edit your account configuration"
          />
        }
      />
    );
  }

  const [main, sub] = page;
  const info = menu[main]?.[sub];
  console.log("info = ", info);
  return (
    <Layout>
      <Sider width={200}>
        {isBrowser && <ConfigMenu main={main} sub={sub} />}
      </Sider>
      <Layout
        style={{
          padding: "0 24px 24px",
          backgroundColor: "white",
          color: "#555",
        }}
      >
        <Content
          style={{
            padding: 24,
            margin: 0,
            minHeight: 280,
          }}
        >
          {info && (
            <h2>
              <Icon name={info.icon} /> {info.title}
            </h2>
          )}
          {(!info?.desc || info.desc.toLowerCase().includes("todo")) && (
            <Alert
              style={{ margin: "15px auto", maxWidth: "600px" }}
              message={<b>Under Constructions</b>}
              description={
                <>
                  This page is under construction. To configure your CoCalc
                  account, visit{" "}
                  <A href={join(basePath, "settings")} external>
                    Account Preferences
                  </A>
                  .
                </>
              }
              type="warning"
              showIcon
            />
          )}
          <Config main={main} sub={sub} />
        </Content>
      </Layout>
    </Layout>
  );
}
