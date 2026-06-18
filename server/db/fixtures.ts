/**
 * Seed data extracted verbatim from the legacy dashboard mocks. Once seeded, the
 * database — not these mocks — is the source of truth (the Umi mocks are disabled
 * in a later milestone).
 *
 * Sources:
 *   - dashboard/mock/utils.ts  -> `defaultUser` (profile + tags)
 *   - dashboard/mock/user.ts    -> `GET /api/users` raw array (fakeList)
 *   - dashboard/mock/notices.ts -> notices array
 */

export interface UserTagSeed {
  key: string;
  label: string;
}

export interface UserSeed {
  userid: string;
  username: string;
  /** Plaintext dev password; hashed by the seed script before insertion. */
  password: string;
  access: 'admin' | 'user';
  name: string;
  avatar: string;
  email: string;
  signature: string;
  title: string;
  group: string;
  notifyCount: number;
  unreadCount: number;
  country: string;
  geographic: {
    province: { label: string; key: string };
    city: { label: string; key: string };
  };
  address: string;
  phone: string;
  tags: UserTagSeed[];
}

export interface NoticeSeed {
  id: string;
  type: 'notification' | 'message' | 'event';
  title: string;
  description?: string;
  avatar?: string;
  datetime?: string;
  status?: string;
  extra?: string;
  read?: boolean;
  clickClose?: boolean;
}

export interface FakeListSeed {
  key: string;
  name: string;
  age: number;
  address: string;
}

// defaultUser from dashboard/mock/utils.ts (shared profile for both logins).
const defaultProfile = {
  name: 'Serati Ma',
  avatar: 'https://gw.alipayobjects.com/zos/antfincdn/XAosXuNZyF/BiazfanxmamNRoxxVxka.png',
  email: 'antdesign@alipay.com',
  signature: '海纳百川，有容乃大',
  title: '交互专家',
  group: '蚂蚁集团－某某某事业群－某某平台部－某某技术部－UED',
  notifyCount: 12,
  unreadCount: 11,
  country: 'China',
  geographic: {
    province: { label: '浙江省', key: '330000' },
    city: { label: '杭州市', key: '330100' },
  },
  address: '西湖区工专路 77 号',
  phone: '0752-268888888',
} as const;

const defaultTags: UserTagSeed[] = [
  { key: '0', label: '很有想法的' },
  { key: '1', label: '专注设计' },
  { key: '2', label: '辣~' },
  { key: '3', label: '大长腿' },
  { key: '4', label: '川妹子' },
  { key: '5', label: '海纳百川' },
];

// The two mock logins (admin/user, password `ant.design`) share the defaultUser
// profile and differ only by access level.
export const userSeeds: UserSeed[] = [
  {
    ...defaultProfile,
    userid: '00000001',
    username: 'admin',
    password: 'ant.design',
    access: 'admin',
    tags: defaultTags,
  },
  {
    ...defaultProfile,
    userid: '00000002',
    username: 'user',
    password: 'ant.design',
    access: 'user',
    email: 'user@alipay.com',
    tags: defaultTags,
  },
];

// Notices array from dashboard/mock/notices.ts (order preserved via array index).
export const noticeSeeds: NoticeSeed[] = [
  {
    id: '000000001',
    avatar: 'https://mdn.alipayobjects.com/yuyan_qk0oxh/afts/img/MSbDR4FR2MUAAAAAAAAAAAAAFl94AQBr',
    title: '你收到了 14 份新周报',
    datetime: '2017-08-09',
    type: 'notification',
  },
  {
    id: '000000002',
    avatar: 'https://mdn.alipayobjects.com/yuyan_qk0oxh/afts/img/hX-PTavYIq4AAAAAAAAAAAAAFl94AQBr',
    title: '你推荐的 曲妮妮 已通过第三轮面试',
    datetime: '2017-08-08',
    type: 'notification',
  },
  {
    id: '000000003',
    avatar: 'https://mdn.alipayobjects.com/yuyan_qk0oxh/afts/img/jHX5R5l3QjQAAAAAAAAAAAAAFl94AQBr',
    title: '这种模板可以区分多种通知类型',
    datetime: '2017-08-07',
    read: true,
    type: 'notification',
  },
  {
    id: '000000004',
    avatar: 'https://mdn.alipayobjects.com/yuyan_qk0oxh/afts/img/Wr4mQqx6jfwAAAAAAAAAAAAAFl94AQBr',
    title: '左侧图标用于区分不同的类型',
    datetime: '2017-08-07',
    type: 'notification',
  },
  {
    id: '000000005',
    avatar: 'https://mdn.alipayobjects.com/yuyan_qk0oxh/afts/img/Mzj_TbcWUj4AAAAAAAAAAAAAFl94AQBr',
    title: '内容不要超过两行字，超出时自动截断',
    datetime: '2017-08-07',
    type: 'notification',
  },
  {
    id: '000000006',
    avatar: 'https://mdn.alipayobjects.com/yuyan_qk0oxh/afts/img/eXLzRbPqQE4AAAAAAAAAAAAAFl94AQBr',
    title: '曲丽丽 评论了你',
    description: '描述信息描述信息描述信息',
    datetime: '2017-08-07',
    type: 'message',
    clickClose: true,
  },
  {
    id: '000000007',
    avatar: 'https://mdn.alipayobjects.com/yuyan_qk0oxh/afts/img/w5mRQY2AmEEAAAAAAAAAAAAAFl94AQBr',
    title: '朱偏右 回复了你',
    description: '这种模板用于提醒谁与你发生了互动，左侧放『谁』的头像',
    datetime: '2017-08-07',
    type: 'message',
    clickClose: true,
  },
  {
    id: '000000008',
    avatar: 'https://mdn.alipayobjects.com/yuyan_qk0oxh/afts/img/wPadR5M9918AAAAAAAAAAAAAFl94AQBr',
    title: '标题',
    description: '这种模板用于提醒谁与你发生了互动，左侧放『谁』的头像',
    datetime: '2017-08-07',
    type: 'message',
    clickClose: true,
  },
  {
    id: '000000009',
    title: '任务名称',
    description: '任务需要在 2017-01-12 20:00 前启动',
    extra: '未开始',
    status: 'todo',
    type: 'event',
  },
  {
    id: '000000010',
    title: '第三方紧急代码变更',
    description: '冠霖提交于 2017-01-06，需在 2017-01-07 前完成代码变更任务',
    extra: '马上到期',
    status: 'urgent',
    type: 'event',
  },
  {
    id: '000000011',
    title: '信息安全考试',
    description: '指派竹尔于 2017-01-09 前完成更新并发布',
    extra: '已耗时 8 天',
    status: 'doing',
    type: 'event',
  },
  {
    id: '000000012',
    title: 'ABCD 版本发布',
    description: '冠霖提交于 2017-01-06，需在 2017-01-07 前完成代码变更任务',
    extra: '进行中',
    status: 'processing',
    type: 'event',
  },
];

// Raw array from `GET /api/users` in dashboard/mock/user.ts.
export const fakeListSeeds: FakeListSeed[] = [
  { key: '1', name: 'John Brown', age: 32, address: 'New York No. 1 Lake Park' },
  { key: '2', name: 'Jim Green', age: 42, address: 'London No. 1 Lake Park' },
  { key: '3', name: 'Joe Black', age: 32, address: 'Sidney No. 1 Lake Park' },
];
