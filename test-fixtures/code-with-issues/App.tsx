import React from 'react';

// LINT ISSUE: Using 'any' type instead of proper interface
const Dashboard: React.FC<any> = (props) => {
  // LINT ISSUE: console.log left in production code
  console.log('Dashboard rendered', props);

  // SECURITY ISSUE: Rendering unsanitized user content directly
  const content = props.userContent;

  return (
    <div>
      <h1>Dashboard</h1>
      <iframe src={content} title="user-content" />
    </div>
  );
};

export default Dashboard;
