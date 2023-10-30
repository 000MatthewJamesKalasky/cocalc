import { Button, Modal, Spin } from "antd";
import { Icon } from "@cocalc/frontend/components";
import { createServer, computeServerAction } from "./api";
import { useEffect, useState } from "react";
import { availableClouds } from "./config";
import {
  CLOUDS_BY_NAME,
  Cloud as CloudType,
} from "@cocalc/util/db-schema/compute-servers";
import ShowError from "@cocalc/frontend/components/error";
import ComputeServer from "./compute-server";
import { useTypedRedux } from "@cocalc/frontend/app-framework";
import { randomColor } from "./color";

const DEFAULTS = {
  title: () => `Untitled ${new Date().toISOString().split("T")[0]}`,
  cloud: availableClouds()[0],
  configuration: CLOUDS_BY_NAME[availableClouds()[0]]?.defaultConfiguration,
};

export default function CreateComputeServer({ project_id, onCreate }) {
  const account_id = useTypedRedux("account", "account_id");
  const [editing, setEditing] = useState<boolean>(false);
  const [creating, setCreating] = useState<boolean>(false);
  const [error, setError] = useState<string>("");

  const [title, setTitle] = useState<string>(DEFAULTS.title);
  const [color, setColor] = useState<string>(randomColor());
  const [cloud, setCloud] = useState<CloudType>(DEFAULTS.cloud);
  const [configuration, setConfiguration] = useState<any>(
    DEFAULTS.configuration,
  );

  const resetConfig = () => {
    setTitle(DEFAULTS.title());
    setColor(randomColor());
    setCloud(DEFAULTS.cloud);
    setConfiguration(DEFAULTS.configuration);
  };

  useEffect(() => {
    if (configuration != null && configuration.cloud != cloud) {
      setConfiguration(CLOUDS_BY_NAME[cloud].defaultConfiguration);
    }
  }, [cloud]);

  const handleCreate = async (start: boolean) => {
    try {
      setError("");
      onCreate();
      try {
        setCreating(true);
        const id = await createServer({
          project_id,
          cloud,
          title,
          color,
          configuration,
        });
        setEditing(false);
        resetConfig();
        setCreating(false);
        if (start) {
          (async () => {
            try {
              await computeServerAction({ id, action: "start" });
            } catch (_) {}
          })();
        }
      } catch (err) {
        setError(`${err}`);
      }
    } finally {
      setCreating(false);
    }
  };

  const footer = [
    <div style={{ textAlign: "center" }} key="footer">
      <Button key="cancel" size="large" onClick={() => setEditing(false)}>
        Cancel
      </Button>
      {cloud != "onprem" && (
        <Button
          key="start"
          size="large"
          type="primary"
          onClick={() => {
            handleCreate(true);
          }}
          disabled={!!error || !title.trim()}
        >
          <Icon name="run" /> Start Compute Server
          {!!error && "(clear error) "}
          {!title.trim() && "(set title) "}
        </Button>
      )}
      <Button
        key="create"
        size="large"
        onClick={() => {
          handleCreate(false);
        }}
        disabled={!!error || !title.trim()}
      >
        <Icon name="run" /> Create Server
        {!!error && "(clear error) "}
        {!title.trim() && "(set title) "}
      </Button>
    </div>,
  ];

  return (
    <div style={{ marginTop: "15px" }}>
      <Button
        size="large"
        disabled={creating || editing}
        onClick={() => {
          setEditing(true);
        }}
        style={{
          marginRight: "5px",
          width: "80%",
          height: "auto",
          whiteSpace: "normal",
          padding: "10px",
          ...(creating
            ? {
                borderColor: "rgb(22, 119, 255)",
                backgroundColor: "rgb(230, 244, 255)",
              }
            : undefined),
        }}
      >
        <Icon
          name="server"
          style={{
            color: "rgb(66, 139, 202)",
            fontSize: "200%",
          }}
        />
        <br />
        Create Compute Server... {creating ? <Spin /> : null}
      </Button>
      <Modal
        maskStyle={{ background: color, opacity: 0.5 }}
        width={"900px"}
        onCancel={() => {
          setEditing(false);
          resetConfig();
        }}
        open={editing}
        title={"Create Compute Server"}
        footer={footer}
      >
        <div style={{ marginTop: "15px" }}>
          <ShowError error={error} setError={setError} />
          <div
            style={{
              marginBottom: "5px",
              color: "#666",
              textAlign: "center",
            }}
          >
            Customize your compute server below, then{" "}
            <Button
              onClick={() => handleCreate(true)}
              disabled={!!error || !title.trim()}
            >
              <Icon name="run" /> Start It
            </Button>
          </div>
          <ComputeServer
            project_id={project_id}
            account_id={account_id}
            title={title}
            color={color}
            cloud={cloud}
            configuration={configuration}
            editable={!creating}
            onColorChange={setColor}
            onTitleChange={setTitle}
            onCloudChange={setCloud}
            onConfigurationChange={setConfiguration}
          />
        </div>
      </Modal>
    </div>
  );
}
