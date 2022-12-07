/*
 *  This file is part of CoCalc: Copyright © 2022 Sagemath, Inc.
 *  License: AGPLv3 s.t. "Commons Clause" – see LICENSE.md for details
 */

import { Row, Col } from "antd";
import withCustomize from "lib/with-customize";
import Header from "components/landing/header";
import Head from "components/landing/head";
import Footer from "components/landing/footer";
import SanitizedMarkdown from "components/misc/sanitized-markdown";
import { Customize } from "lib/customize";

export default function Policies({ customize }) {
  const { policies } = customize;
  return (
    <Customize value={customize}>
      <Head title="Policies" />
      <Layout>
        <Header page="policies" subPage="policies" />
        <Row>
          <Col
            xs={{ span: 12, offset: 6 }}
            style={{ marginTop: "30px", marginBottom: "30px" }}
          >
            {policies && <SanitizedMarkdown value={policies} />}
          </Col>
        </Row>
        <Footer />{" "}
      </Layout>
    </Customize>
  );
}

export async function getServerSideProps(context) {
  return await withCustomize({ context });
}
